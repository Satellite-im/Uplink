use std::{ffi::OsStr, path::PathBuf};

use common::{
    state::{storage::Storage, State},
    warp_runner::ConstellationCmd,
    WARP_CMD_CH,
};
use dioxus_core::{ScopeState, Scoped};
use dioxus_desktop::DesktopContext;
use dioxus_hooks::{
    to_owned, use_coroutine, use_ref, use_state, Coroutine, UnboundedReceiver, UseRef,
    UseSharedState, UseState,
};
use futures::StreamExt;
use warp::constellation::directory::Directory;
use wry::webview::FileDropEvent;

use crate::layouts::storage::{
    datasource::remote::StorageRemoteDataSource, domain::repository::StorageRepository,
};

use super::ui::{ChanCmd, Props, DRAG_EVENT};

#[derive(Clone)]
pub struct StorageController<'a> {
    pub storage_state: &'a UseState<Option<Storage>>,
    pub directories_list: &'a UseRef<Vec<Directory>>,
    pub files_list: &'a UseRef<Vec<warp::constellation::file::File>>,
    pub current_dir: &'a UseRef<Directory>,
    pub dirs_opened_ref: &'a UseRef<Vec<Directory>>,
    storage_repository: &'a StorageRepository,
}

impl<'a> StorageController<'a> {
    pub fn new(cx: &'a ScopeState, state: UseSharedState<State>) -> Self {
        Self {
            storage_state: use_state(cx, || None),
            directories_list: use_ref(cx, || state.read().storage.directories.clone()),
            files_list: use_ref(cx, || state.read().storage.files.clone()),
            current_dir: use_ref(cx, || state.read().storage.current_dir.clone()),
            dirs_opened_ref: use_ref(cx, || state.read().storage.directories_opened.clone()),
            storage_repository: &StorageRepository::new(),
        }
    }
}

pub trait ControllerFunctions {
    fn get_drag_event(&self) -> FileDropEvent;
    fn format_item_name(file_name: String) -> String;
    fn storage_coroutine<'b>(
        &self,
        cx: &'b Scoped<'b, Props>,
        state: &UseSharedState<State>,
        storage_state: &'b UseState<Option<Storage>>,
        storage_size: &'b UseRef<(String, String)>,
        main_script: String,
        window: &'b DesktopContext,
        drag_event: &'b UseRef<Option<FileDropEvent>>,
    ) -> &'b Coroutine<ChanCmd>;
}

impl<'a> ControllerFunctions for StorageController<'a> {
    fn get_drag_event(&self) -> FileDropEvent {
        DRAG_EVENT.read().clone()
    }

    fn format_item_name(file_name: String) -> String {
        let item = PathBuf::from(&file_name);

        let file_stem = item
            .file_stem()
            .and_then(OsStr::to_str)
            .map(str::to_string)
            .unwrap_or_default();

        file_name
            .get(0..15)
            .map(|x| x.to_string())
            .map(|x| {
                if file_stem.len() > 15 {
                    format!("{x}...")
                } else {
                    x
                }
            })
            .unwrap_or_else(|| file_name.clone())
    }

    fn storage_coroutine<'b>(
        &self,
        cx: &'b Scoped<'b, Props>,
        state: &UseSharedState<State>,
        storage_state: &'b UseState<Option<Storage>>,
        storage_size: &'b UseRef<(String, String)>,
        main_script: String,
        window: &'b DesktopContext,
        drag_event: &'b UseRef<Option<FileDropEvent>>,
    ) -> &'b Coroutine<ChanCmd> {
        let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<ChanCmd>| {
            to_owned![
                storage_state,
                main_script,
                window,
                drag_event,
                storage_size,
                state
            ];
            async move {
                let warp_cmd_tx = WARP_CMD_CH.tx.clone();
                while let Some(cmd) = rx.next().await {
                    match cmd {
                        ChanCmd::CreateNewDirectory(directory_name) => {
                            match self
                                .storage_repository
                                .create_new_directory(directory_name)
                                .await
                            {
                                Ok(()) => log::info!("New directory added: {}", directory_name),
                                Err(e) => continue,
                            }
                        }
                        ChanCmd::GetItemsFromCurrentDirectory => {
                            match self
                                .storage_repository
                                .get_items_from_current_directory()
                                .await
                            {
                                Ok(storage) => {
                                    storage_state.set(Some(storage));
                                }
                                Err(e) => continue,
                            }
                        }
                        ChanCmd::OpenDirectory(directory_name) => {
                            let (tx, rx) =
                                oneshot::channel::<Result<Storage, warp::error::Error>>();
                            let directory_name2 = directory_name.clone();

                            if let Err(e) = warp_cmd_tx.send(WarpCmd::Constellation(
                                ConstellationCmd::OpenDirectory {
                                    directory_name,
                                    rsp: tx,
                                },
                            )) {
                                log::error!("failed to open {directory_name2} directory {}", e);
                                continue;
                            }

                            let rsp = rx.await.expect("command canceled");
                            match rsp {
                                Ok(storage) => {
                                    storage_state.set(Some(storage));
                                    log::info!("Folder {} opened", directory_name2);
                                }
                                Err(e) => {
                                    log::error!("failed to open folder {directory_name2}: {}", e);
                                    continue;
                                }
                            }
                        }
                        ChanCmd::BackToPreviousDirectory(directory) => {
                            let (tx, rx) =
                                oneshot::channel::<Result<Storage, warp::error::Error>>();
                            let directory_name = directory.name();

                            if let Err(e) = warp_cmd_tx.send(WarpCmd::Constellation(
                                ConstellationCmd::BackToPreviousDirectory { directory, rsp: tx },
                            )) {
                                log::error!("failed to open directory {}: {}", directory_name, e);
                                continue;
                            }

                            let rsp = rx.await.expect("command canceled");
                            match rsp {
                                Ok(storage) => {
                                    storage_state.set(Some(storage));
                                    log::info!("Folder {} opened", directory_name);
                                }
                                Err(e) => {
                                    log::error!(
                                        "failed to open directory {}: {}",
                                        directory_name,
                                        e
                                    );
                                    continue;
                                }
                            }
                        }
                        ChanCmd::UploadFiles(files_path) => {
                            let mut script = main_script.replace("$IS_DRAGGING", "true");
                            script.push_str(ANIMATION_DASH_SCRIPT);
                            window.eval(&script);

                            let (tx, mut rx) =
                                mpsc::unbounded_channel::<FileTransferProgress<Storage>>();

                            if let Err(e) = warp_cmd_tx.send(WarpCmd::Constellation(
                                ConstellationCmd::UploadFiles {
                                    files_path,
                                    rsp: tx,
                                },
                            )) {
                                log::error!("failed to upload files {}", e);
                                continue;
                            }
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
                                                let file_name_formatted = format_item_name(name);
                                                let script = FILE_NAME_SCRIPT
                                                    .replace("$FILE_NAME", &file_name_formatted);
                                                window.eval(&script);
                                                sleep(Duration::from_millis(100)).await;
                                            }
                                            FileTransferStep::DuplicateName(
                                                duplicate_name_step,
                                            ) => {
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
                                                            format_item_name(name);
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
                                                            &get_local_text(
                                                                "files.thumbnail-uploaded",
                                                            ),
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
                                            main_script.replace("$IS_DRAGGING", "false");
                                        script.push_str(&FEEDBACK_TEXT_SCRIPT.replace("$TEXT", ""));
                                        script
                                            .push_str(&FILE_NAME_SCRIPT.replace("$FILE_NAME", ""));
                                        script
                                            .push_str(&ANIMATION_DASH_SCRIPT.replace("0.5s", "0s"));
                                        window.eval(&script);
                                        storage_state.set(Some(storage));
                                        break;
                                    }
                                    FileTransferProgress::Error(_) => {
                                        *drag_event.write_silent() = None;
                                        let mut script =
                                            main_script.replace("$IS_DRAGGING", "false");
                                        script.push_str(&FEEDBACK_TEXT_SCRIPT.replace("$TEXT", ""));
                                        script
                                            .push_str(&FILE_NAME_SCRIPT.replace("$FILE_NAME", ""));
                                        script
                                            .push_str(&ANIMATION_DASH_SCRIPT.replace("0.5s", "0s"));
                                        window.eval(&script);
                                        break;
                                    }
                                }
                            }
                        }
                        ChanCmd::DownloadFile {
                            file_name,
                            local_path_to_save_file,
                        } => {
                            let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();

                            if let Err(e) = warp_cmd_tx.send(WarpCmd::Constellation(
                                ConstellationCmd::DownloadFile {
                                    file_name,
                                    local_path_to_save_file,
                                    rsp: tx,
                                },
                            )) {
                                log::error!("failed to download file {}", e);
                                continue;
                            }

                            let rsp = rx.await.expect("command canceled");

                            if let Err(error) = rsp {
                                log::error!("failed to download file: {}", error);
                                continue;
                            }
                        }
                        ChanCmd::RenameItem { old_name, new_name } => {
                            let (tx, rx) =
                                oneshot::channel::<Result<Storage, warp::error::Error>>();

                            if let Err(e) = warp_cmd_tx.send(WarpCmd::Constellation(
                                ConstellationCmd::RenameItem {
                                    old_name,
                                    new_name,
                                    rsp: tx,
                                },
                            )) {
                                log::error!("failed to rename item {}", e);
                                continue;
                            }

                            let rsp = rx.await.expect("command canceled");
                            match rsp {
                                Ok(storage) => {
                                    storage_state.set(Some(storage));
                                }
                                Err(e) => {
                                    log::error!(
                                        "failed to update uplink storage with renamed item: {}",
                                        e
                                    );
                                    continue;
                                }
                            }
                        }
                        ChanCmd::DeleteItems(item) => {
                            let (tx, rx) =
                                oneshot::channel::<Result<Storage, warp::error::Error>>();

                            if let Err(e) = warp_cmd_tx.send(WarpCmd::Constellation(
                                ConstellationCmd::DeleteItems {
                                    item: item.clone(),
                                    rsp: tx,
                                },
                            )) {
                                log::error!("failed to delete items {}, item {:?}", e, item.name());
                                continue;
                            }

                            let rsp = rx.await.expect("command canceled");
                            match rsp {
                                Ok(storage) => {
                                    storage_state.set(Some(storage));
                                }
                                Err(e) => {
                                    log::error!(
                                        "failed to delete items {}, item {:?}",
                                        e,
                                        item.name()
                                    );
                                    continue;
                                }
                            }
                        }
                        ChanCmd::GetStorageSize => {
                            let (tx, rx) =
                                oneshot::channel::<Result<(usize, usize), warp::error::Error>>();

                            if let Err(e) = warp_cmd_tx.send(WarpCmd::Constellation(
                                ConstellationCmd::GetStorageSize { rsp: tx },
                            )) {
                                log::error!("failed to get storage size: {}", e);
                                continue;
                            }

                            let rsp = rx.await.expect("command canceled");
                            match rsp {
                                Ok((max_size, current_size)) => {
                                    let max_storage_size = format_item_size(max_size);
                                    let current_storage_size = format_item_size(current_size);
                                    storage_size.with_mut(|i| {
                                        *i = (max_storage_size, current_storage_size)
                                    });
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
                            }
                        }
                    }
                }
            }
        });
        ch
    }
}
