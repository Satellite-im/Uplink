use std::{path::PathBuf, time::Duration};

use common::{
    language::get_local_text,
    state::{storage::Storage, State, ToastNotification},
    warp_runner::{FileTransferProgress, FileTransferStep},
};

use dioxus_core::ScopeState;
use dioxus_desktop::{use_window, DesktopContext};
use dioxus_hooks::{
    to_owned, use_coroutine, use_ref, use_state, Coroutine, UnboundedReceiver, UseRef,
    UseSharedState, UseState,
};
use futures::StreamExt;
use tokio::time::sleep;
use warp::constellation::{directory::Directory, item::Item};
use wry::webview::FileDropEvent;

use crate::layouts::storage::{
    domain::repository::StorageRepository,
    presentation::{
        controller::events,
        view::scripts::{
            ANIMATION_DASH_SCRIPT, FEEDBACK_TEXT_SCRIPT, FILE_NAME_SCRIPT, MAIN_SCRIPT_JS,
        },
    },
};

#[derive(Clone)]
pub struct StorageController<'a> {
    pub storage_state: &'a UseState<Option<Storage>>,
    pub storage_size: &'a UseRef<(String, String)>,
    pub directories_list: &'a UseRef<Vec<Directory>>,
    pub files_list: &'a UseRef<Vec<warp::constellation::file::File>>,
    pub current_dir: &'a UseRef<Directory>,
    pub dirs_opened_ref: &'a UseRef<Vec<Directory>>,
    pub drag_event: &'a UseRef<Option<FileDropEvent>>,
    pub coroutine: &'a Coroutine<ChanCmd>,
    pub repository: StorageRepository,
}

impl<'a> StorageController<'a> {
    pub fn new(cx: &'a ScopeState, state: &'a UseSharedState<State>) -> Self {
        let window = use_window(cx);
        let storage_state = use_state(cx, || None);
        let storage_size = use_ref(cx, || (String::new(), String::new()));
        let directories_list = use_ref(cx, || state.read().storage.directories.clone());
        let files_list = use_ref(cx, || state.read().storage.files.clone());
        let current_dir = use_ref(cx, || state.read().storage.current_dir.clone());
        let dirs_opened_ref = use_ref(cx, || state.read().storage.directories_opened.clone());
        let drag_event = use_ref(cx, || None);
        let repository = StorageRepository::new();
        let coroutine = init_coroutine(
            cx,
            state,
            window,
            drag_event,
            storage_state,
            storage_size,
            repository.clone(),
        );

        let controller = Self {
            storage_state,
            storage_size,
            directories_list,
            files_list,
            current_dir,
            dirs_opened_ref,
            drag_event,
            coroutine,
            repository,
        };
        controller
    }
}

pub enum ChanCmd {
    GetItemsFromCurrentDirectory,
    CreateNewDirectory(String),
    OpenDirectory(String),
    BackToPreviousDirectory(Directory),
    UploadFiles(Vec<PathBuf>),
    DownloadFile {
        file_name: String,
        local_path_to_save_file: PathBuf,
    },
    RenameItem {
        old_name: String,
        new_name: String,
    },
    DeleteItems(Item),
    GetStorageSize,
}

// Impl for coroutine
impl<'a> StorageController<'a> {
    pub fn ch_send(&self, command: ChanCmd) {
        self.coroutine.send(command);
    }
}

pub fn init_coroutine<'a>(
    cx: &'a ScopeState,
    state: &'a UseSharedState<State>,
    window: &'a DesktopContext,
    drag_event: &UseRef<Option<FileDropEvent>>,
    storage_state: &UseState<Option<Storage>>,
    storage_size: &UseRef<(String, String)>,
    repository: StorageRepository,
) -> &'a Coroutine<ChanCmd> {
    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<ChanCmd>| {
        to_owned![
            window,
            state,
            drag_event,
            storage_state,
            storage_size,
            repository
        ];
        async move {
            while let Some(cmd) = rx.next().await {
                match cmd {
                    ChanCmd::CreateNewDirectory(directory_name) => {
                        let directory_name_clone = directory_name.clone();
                        match repository.create_new_directory(directory_name).await {
                            Ok(()) => {
                                log::info!("New directory added: {}", directory_name_clone)
                            }
                            Err(e) => continue,
                        }
                    }
                    ChanCmd::GetItemsFromCurrentDirectory => {
                        match repository.get_items_from_current_directory().await {
                            Ok(storage) => storage_state.set(Some(storage)),
                            Err(_) => continue,
                        }
                    }
                    ChanCmd::OpenDirectory(directory_name) => {
                        match repository.open_directory(directory_name).await {
                            Ok(storage) => storage_state.set(Some(storage)),
                            Err(_) => continue,
                        }
                    }
                    ChanCmd::BackToPreviousDirectory(directory) => {
                        match repository.back_to_previous_directory(directory).await {
                            Ok(storage) => storage_state.set(Some(storage)),
                            Err(_) => continue,
                        }
                    }
                    ChanCmd::DownloadFile {
                        file_name,
                        local_path_to_save_file,
                    } => {
                        let file_name_clone = file_name.clone();
                        match repository
                            .download_file(file_name, local_path_to_save_file)
                            .await
                        {
                            Ok(()) => log::info!("File downloaded: {}", file_name_clone),
                            Err(_) => continue,
                        }
                    }
                    ChanCmd::RenameItem { old_name, new_name } => {
                        match repository.rename_item(old_name, new_name).await {
                            Ok(storage) => storage_state.set(Some(storage)),
                            Err(_) => continue,
                        }
                    }
                    ChanCmd::DeleteItems(item) => match repository.delete_item(item).await {
                        Ok(storage) => storage_state.set(Some(storage)),
                        Err(_) => continue,
                    },
                    ChanCmd::GetStorageSize => match repository.get_storage_size().await {
                        Ok((max_size, current_size)) => {
                            let max_storage_size = events::format_item_size(max_size);
                            let current_storage_size = events::format_item_size(current_size);

                            storage_size
                                .with_mut(|i| *i = (max_storage_size, current_storage_size));
                        }
                        Err(e) => {
                            storage_size.with_mut(|i| {
                                *i = (
                                    get_local_text("files.no-data-available"),
                                    get_local_text("files.no-data-available"),
                                )
                            });
                            log::error!("failed to get storage size: {}", e);
                            continue;
                        }
                    },
                    ChanCmd::UploadFiles(files_path) => {
                        let mut script = MAIN_SCRIPT_JS.replace("$IS_DRAGGING", "true");
                        script.push_str(ANIMATION_DASH_SCRIPT);
                        window.eval(&script);

                        let mut rx = match repository.upload_files(files_path).await {
                            Ok(rx) => rx,
                            Err(_) => continue,
                        };

                        while let Some(msg) = rx.recv().await {
                            match msg {
                                FileTransferProgress::Step(steps) => {
                                    match steps {
                                        FileTransferStep::SizeNotAvailable(file_name) => {
                                            state.write().mutate(
                                                common::state::Action::AddToastNotification(
                                                    ToastNotification::init(
                                                        "".into(),
                                                        format!(
                                                            "{} {}",
                                                            get_local_text(
                                                                "files.no-size-available"
                                                            ),
                                                            file_name
                                                        ),
                                                        None,
                                                        3,
                                                    ),
                                                ),
                                            );
                                            sleep(Duration::from_millis(1000)).await;
                                        }
                                        FileTransferStep::Start(name) => {
                                            let file_name_formatted =
                                                events::format_item_name(name);
                                            let script = FILE_NAME_SCRIPT
                                                .replace("$FILE_NAME", &file_name_formatted);
                                            window.eval(&script);
                                            sleep(Duration::from_millis(100)).await;
                                        }
                                        FileTransferStep::DuplicateName(duplicate_name_step) => {
                                            match duplicate_name_step {
                                                None => {
                                                    let script = FEEDBACK_TEXT_SCRIPT.replace(
                                                        "$TEXT",
                                                        &get_local_text(
                                                            "files.renaming-duplicated",
                                                        ),
                                                    );
                                                    window.eval(&script);
                                                }
                                                Some(name) => {
                                                    let file_name_formatted =
                                                        events::format_item_name(name);
                                                    let script = FILE_NAME_SCRIPT.replace(
                                                        "$FILE_NAME",
                                                        &file_name_formatted,
                                                    );
                                                    window.eval(&script);
                                                }
                                            }
                                            sleep(Duration::from_millis(200)).await;
                                        }
                                        FileTransferStep::Upload(progress) => {
                                            let script = FEEDBACK_TEXT_SCRIPT.replace(
                                                "$TEXT",
                                                &format!(
                                                    "{} {}",
                                                    progress,
                                                    get_local_text("files.uploaded")
                                                ),
                                            );
                                            window.eval(&script);
                                            sleep(Duration::from_millis(3)).await;
                                        }
                                        FileTransferStep::Thumbnail(thumb_type) => {
                                            match thumb_type {
                                                Some(_) => {
                                                    let script = FEEDBACK_TEXT_SCRIPT.replace(
                                                        "$TEXT",
                                                        &get_local_text("files.thumbnail-uploaded"),
                                                    );
                                                    window.eval(&script);
                                                }
                                                None => {
                                                    let script = FEEDBACK_TEXT_SCRIPT.replace(
                                                        "$TEXT",
                                                        &get_local_text("files.no-thumbnail"),
                                                    );
                                                    window.eval(&script);
                                                }
                                            }
                                            sleep(Duration::from_millis(200)).await;
                                        }
                                    };
                                }
                                FileTransferProgress::Finished(storage) => {
                                    *drag_event.write_silent() = None;
                                    let mut script =
                                        MAIN_SCRIPT_JS.replace("$IS_DRAGGING", "false");
                                    script.push_str(&FEEDBACK_TEXT_SCRIPT.replace("$TEXT", ""));
                                    script.push_str(&FILE_NAME_SCRIPT.replace("$FILE_NAME", ""));
                                    script.push_str(&ANIMATION_DASH_SCRIPT.replace("0.5s", "0s"));
                                    window.eval(&script);
                                    storage_state.set(Some(storage));
                                    break;
                                }
                                FileTransferProgress::Error(_) => {
                                    *drag_event.write_silent() = None;
                                    let mut script =
                                        MAIN_SCRIPT_JS.replace("$IS_DRAGGING", "false");
                                    script.push_str(&FEEDBACK_TEXT_SCRIPT.replace("$TEXT", ""));
                                    script.push_str(&FILE_NAME_SCRIPT.replace("$FILE_NAME", ""));
                                    script.push_str(&ANIMATION_DASH_SCRIPT.replace("0.5s", "0s"));
                                    window.eval(&script);
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        }
    });
    ch
}
