use common::state::{storage::Storage, State};

use dioxus_core::ScopeState;
use dioxus_desktop::use_window;
use dioxus_hooks::{use_ref, use_state, UseRef, UseSharedState, UseState};

use warp::constellation::directory::Directory;
use wry::webview::FileDropEvent;

#[derive(Clone)]
pub struct StorageController<'a> {
    pub storage_state: &'a UseState<Option<Storage>>,
    pub storage_size: &'a UseRef<(String, String)>,
    pub directories_list: &'a UseRef<Vec<Directory>>,
    pub files_list: &'a UseRef<Vec<warp::constellation::file::File>>,
    pub current_dir: &'a UseRef<Directory>,
    pub dirs_opened_ref: &'a UseRef<Vec<Directory>>,
    pub drag_event: &'a UseRef<Option<FileDropEvent>>,
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

        let controller = Self {
            storage_state,
            storage_size,
            directories_list,
            files_list,
            current_dir,
            dirs_opened_ref,
            drag_event,
        };
        controller
    }
}
