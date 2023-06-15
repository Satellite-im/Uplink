use common::state::{storage::Storage, State};

use dioxus_core::ScopeState;
use dioxus_hooks::{use_ref, UseRef, UseSharedState};

use uuid::Uuid;
use warp::constellation::{directory::Directory, file::File};
use wry::webview::FileDropEvent;

#[derive(Clone)]
pub struct StorageController {
    pub storage_state: Option<Storage>,
    pub storage_size: (String, String),
    pub directories_list: Vec<Directory>,
    pub files_list: Vec<warp::constellation::file::File>,
    pub current_dir: Directory,
    pub dirs_opened_ref: Vec<Directory>,
    pub drag_event: Option<FileDropEvent>,
    pub is_renaming_map: Option<Uuid>,
    pub add_new_folder: bool,
    pub show_file_modal: Option<File>,
    pub first_render: bool,
}

impl StorageController {
    pub fn new<'a>(cx: &'a ScopeState, state: &'a UseSharedState<State>) -> &'a UseRef<Self> {
        let controller = Self {
            storage_state: None,
            storage_size: (String::new(), String::new()),
            directories_list: state.read().storage.directories.clone(),
            files_list: state.read().storage.files.clone(),
            current_dir: state.read().storage.current_dir.clone(),
            dirs_opened_ref: state.read().storage.directories_opened.clone(),
            drag_event: None,
            is_renaming_map: None,
            add_new_folder: false,
            show_file_modal: None,
            first_render: true,
        };

        use_ref(cx, || controller)
    }

    pub fn update_state(&mut self, state: &UseSharedState<State>) -> bool {
        if let Some(storage) = self.storage_state.take() {
            self.directories_list = storage.directories.clone();
            self.files_list = storage.files.clone();
            self.current_dir = storage.current_dir.clone();
            self.dirs_opened_ref = storage.directories_opened.clone();
            state.write().storage = storage;
            true
        } else {
            false
        }
    }

    pub fn finish_renaming_item(&mut self, should_toggle: bool) {
        self.is_renaming_map.take();
        if should_toggle {
            self.add_new_folder = !self.add_new_folder;
        } else {
            self.add_new_folder = false;
        }
    }
}
