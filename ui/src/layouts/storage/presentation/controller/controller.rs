use std::{cell::RefCell, ffi::OsStr, path::PathBuf, rc::Rc, sync::Arc, time::Duration};

use common::{
    language::get_local_text,
    state::{storage::Storage, Action, State, ToastNotification},
    warp_runner::{FileTransferProgress, FileTransferStep},
};

use dioxus_core::{Scope, ScopeState, Scoped};
use dioxus_desktop::DesktopContext;
use dioxus_hooks::{
    to_owned, use_coroutine, use_future, use_ref, use_state, Coroutine, UnboundedReceiver, UseRef,
    UseSharedState, UseState,
};
use futures::StreamExt;
use tokio::time::sleep;
use warp::constellation::{directory::Directory, item::Item};
use wry::webview::FileDropEvent;

use crate::{
    layouts::storage::{
        domain::repository::StorageRepository,
        presentation::view::{
            files_page::Props,
            scripts::{
                ANIMATION_DASH_SCRIPT, FEEDBACK_TEXT_SCRIPT, FILE_NAME_SCRIPT, MAIN_SCRIPT_JS,
            },
        },
    },
    utils::drag_and_drop_files::*,
};

const MAX_LEN_TO_FORMAT_NAME: usize = 15;

#[derive(Clone)]
pub struct StorageController<'a> {
    pub storage_state: &'a UseState<Option<Storage>>,
    pub storage_size: &'a UseRef<(String, String)>,
    pub directories_list: &'a UseRef<Vec<Directory>>,
    pub files_list: &'a UseRef<Vec<warp::constellation::file::File>>,
    pub current_dir: &'a UseRef<Directory>,
    pub dirs_opened_ref: &'a UseRef<Vec<Directory>>,
    pub drag_event: &'a UseRef<Option<FileDropEvent>>,
    coroutine: Option<&'a Coroutine<ChanCmd>>,
    repository: StorageRepository,
}

impl<'a> StorageController<'a> {
    pub fn new(cx: &'a ScopeState, state: &'a UseSharedState<State>) -> Rc<RefCell<Self>> {
        let storage_state = use_state(cx, || None);
        let storage_size = use_ref(cx, || (String::new(), String::new()));
        let directories_list = use_ref(cx, || state.read().storage.directories.clone());
        let files_list = use_ref(cx, || state.read().storage.files.clone());
        let current_dir = use_ref(cx, || state.read().storage.current_dir.clone());
        let dirs_opened_ref = use_ref(cx, || state.read().storage.directories_opened.clone());
        let drag_event = use_ref(cx, || None);
        let repository = StorageRepository::new();

        let controller = Self {
            storage_state,
            storage_size,
            directories_list,
            files_list,
            current_dir,
            dirs_opened_ref,
            drag_event,
            coroutine: None,
            repository,
        };
        Rc::new(RefCell::new(controller))
    }

    pub fn run_verifications_and_update_storage(
        &'a self,
        first_render: &UseState<bool>,
        state: &UseSharedState<State>,
    ) {
        if *first_render.get() && state.read().ui.is_minimal_view() {
            state.write().mutate(Action::SidebarHidden(true));
            first_render.set(false);
        }

        if let Some(storage) = self.storage_state.get().clone() {
            *(self.directories_list).write_silent() = storage.directories.clone();
            *(self.files_list).write_silent() = storage.files.clone();
            *(self.current_dir).write_silent() = storage.current_dir.clone();
            *(self.dirs_opened_ref).write_silent() = storage.directories_opened.clone();
            state.write().storage = storage;
            self.storage_state.set(None);
            self.ch_send(ChanCmd::GetStorageSize);
        }
    }

    pub fn format_item_size(&self, item_size: usize) -> String {
        if item_size == 0 {
            return String::from("0 bytes");
        }
        let base_1024: f64 = 1024.0;
        let size_f64: f64 = item_size as f64;

        let i = (size_f64.log10() / base_1024.log10()).floor();
        let size_formatted = size_f64 / base_1024.powf(i);

        let item_size_suffix = ["bytes", "KB", "MB", "GB", "TB"][i as usize];
        let mut size_formatted_string = format!(
            "{size:.*} {size_suffix}",
            1,
            size = size_formatted,
            size_suffix = item_size_suffix
        );
        if size_formatted_string.contains(".0") {
            size_formatted_string = size_formatted_string.replace(".0", "");
        }
        size_formatted_string
    }

    pub fn allow_drag_event_for_non_macos_systems(
        &'static self,
        cx: &ScopeState,
        window: &'a DesktopContext,
    ) {
        let controller = self.clone();
        use_future(cx, (), |_| {
            // #[cfg(not(target_os = "macos"))]
            to_owned![window, controller];
            // let controller2 = controller.clone();
            async move {
                sleep(Duration::from_millis(300)).await;
                self.ch_send(ChanCmd::GetItemsFromCurrentDirectory);
                // ondragover function from div does not work on windows
                // #[cfg(not(target_os = "macos"))]
                loop {
                    sleep(Duration::from_millis(100)).await;
                    if let FileDropEvent::Hovered { .. } = get_drag_event() {
                        if controller.drag_event.with(|i| i.clone()).is_none() {
                            controller.drag_and_drop_function(&window).await;
                        }
                    }
                }
            }
        });
    }

    pub fn format_item_name(&self, file_name: String) -> String {
        let item = PathBuf::from(&file_name);

        let file_stem = item
            .file_stem()
            .and_then(OsStr::to_str)
            .map(str::to_string)
            .unwrap_or_default();

        file_name
            .get(0..MAX_LEN_TO_FORMAT_NAME)
            .map(|x| x.to_string())
            .map(|x| {
                if file_stem.len() > MAX_LEN_TO_FORMAT_NAME {
                    format!("{x}...")
                } else {
                    x
                }
            })
            .unwrap_or_else(|| file_name.clone())
    }
}

// Impl for drag and drop operations
impl<'a> StorageController<'a> {
    pub async fn drag_and_drop_function(&self, window: &DesktopContext) {
        *self.drag_event.write_silent() = Some(get_drag_event());
        loop {
            let file_drop_event = get_drag_event();
            match file_drop_event {
                FileDropEvent::Hovered { paths, .. } => {
                    if verify_if_there_are_valid_paths(&paths) {
                        let mut script = MAIN_SCRIPT_JS.replace("$IS_DRAGGING", "true");
                        if paths.len() > 1 {
                            script.push_str(&FEEDBACK_TEXT_SCRIPT.replace(
                                "$TEXT",
                                &format!(
                                    "{} {}!",
                                    paths.len(),
                                    get_local_text("files.files-to-upload")
                                ),
                            ));
                        } else {
                            script.push_str(&FEEDBACK_TEXT_SCRIPT.replace(
                                "$TEXT",
                                &format!(
                                    "{} {}!",
                                    paths.len(),
                                    get_local_text("files.one-file-to-upload")
                                ),
                            ));
                        }
                        window.eval(&script);
                    }
                }
                FileDropEvent::Dropped { paths, .. } => {
                    if verify_if_there_are_valid_paths(&paths) {
                        let new_files_to_upload = decoded_pathbufs(paths);
                        self.ch_send(ChanCmd::UploadFiles(new_files_to_upload));
                        break;
                    }
                }
                _ => {
                    *self.drag_event.write_silent() = None;
                    let script = MAIN_SCRIPT_JS.replace("$IS_DRAGGING", "false");
                    window.eval(&script);
                    break;
                }
            };
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
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
        self.coroutine.unwrap().send(command);
    }

    fn init_coroutine<'b>(
        &'static self,
        cx: &'b ScopeState,
        state: &'b UseSharedState<State>,
        window: &'b DesktopContext,
    ) -> &'b Coroutine<ChanCmd> {
        let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<ChanCmd>| {
            to_owned![window, state];
            async move {
                while let Some(cmd) = rx.next().await {
                    match cmd {
                        ChanCmd::CreateNewDirectory(directory_name) => {
                            let directory_name_clone = directory_name.clone();
                            match self.repository.create_new_directory(directory_name).await {
                                Ok(()) => {
                                    log::info!("New directory added: {}", directory_name_clone)
                                }
                                Err(e) => continue,
                            }
                        }
                        ChanCmd::GetItemsFromCurrentDirectory => {
                            match self.repository.get_items_from_current_directory().await {
                                Ok(storage) => self.storage_state.set(Some(storage)),
                                Err(_) => continue,
                            }
                        }
                        ChanCmd::OpenDirectory(directory_name) => {
                            match self.repository.open_directory(directory_name).await {
                                Ok(storage) => self.storage_state.set(Some(storage)),
                                Err(_) => continue,
                            }
                        }
                        ChanCmd::BackToPreviousDirectory(directory) => {
                            match self.repository.back_to_previous_directory(directory).await {
                                Ok(storage) => self.storage_state.set(Some(storage)),
                                Err(_) => continue,
                            }
                        }
                        ChanCmd::DownloadFile {
                            file_name,
                            local_path_to_save_file,
                        } => {
                            let file_name_clone = file_name.clone();
                            match self
                                .repository
                                .download_file(file_name, local_path_to_save_file)
                                .await
                            {
                                Ok(()) => log::info!("File downloaded: {}", file_name_clone),
                                Err(_) => continue,
                            }
                        }
                        ChanCmd::RenameItem { old_name, new_name } => {
                            match self.repository.rename_item(old_name, new_name).await {
                                Ok(storage) => self.storage_state.set(Some(storage)),
                                Err(_) => continue,
                            }
                        }
                        ChanCmd::DeleteItems(item) => {
                            match self.repository.delete_item(item).await {
                                Ok(storage) => self.storage_state.set(Some(storage)),
                                Err(_) => continue,
                            }
                        }
                        ChanCmd::GetStorageSize => match self.repository.get_storage_size().await {
                            Ok((max_size, current_size)) => {
                                let max_storage_size = self.format_item_size(max_size);
                                let current_storage_size = self.format_item_size(current_size);
                                self.storage_size
                                    .with_mut(|i| *i = (max_storage_size, current_storage_size));
                            }
                            Err(e) => {
                                self.storage_size.with_mut(|i| {
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

                            let mut rx = match self.repository.upload_files(files_path).await {
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
                                                    self.format_item_name(name);
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
                                                            self.format_item_name(name);
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
                                        *self.drag_event.write_silent() = None;
                                        let mut script =
                                            MAIN_SCRIPT_JS.replace("$IS_DRAGGING", "false");
                                        script.push_str(&FEEDBACK_TEXT_SCRIPT.replace("$TEXT", ""));
                                        script
                                            .push_str(&FILE_NAME_SCRIPT.replace("$FILE_NAME", ""));
                                        script
                                            .push_str(&ANIMATION_DASH_SCRIPT.replace("0.5s", "0s"));
                                        window.eval(&script);
                                        self.storage_state.set(Some(storage));
                                        break;
                                    }
                                    FileTransferProgress::Error(_) => {
                                        *self.drag_event.write_silent() = None;
                                        let mut script =
                                            MAIN_SCRIPT_JS.replace("$IS_DRAGGING", "false");
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
                    }
                }
            }
        });
        ch
    }
}
