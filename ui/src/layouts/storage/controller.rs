use common::state::{storage::Storage, State};
use dioxus_core::ScopeState;
use dioxus_hooks::{use_ref, use_state, UseRef, UseSharedState, UseState};
use warp::constellation::directory::Directory;

#[derive(PartialEq, Clone)]
pub struct StorageController<'a> {
    pub storage_state: &'a UseState<Option<Storage>>,
    pub directories_list: &'a UseRef<Vec<Directory>>,
    pub files_list: &'a UseRef<Vec<warp::constellation::file::File>>,
    pub current_dir: &'a UseRef<Directory>,
    pub dirs_opened_ref: &'a UseRef<Vec<Directory>>,
}

impl<'a> StorageController<'a> {
    pub fn new(cx: &'a ScopeState, state: UseSharedState<State>) -> Self {
        Self {
            storage_state: use_state(cx, || None),
            directories_list: use_ref(cx, || state.read().storage.directories.clone()),
            files_list: use_ref(cx, || state.read().storage.files.clone()),
            current_dir: use_ref(cx, || state.read().storage.current_dir.clone()),
            dirs_opened_ref: use_ref(cx, || state.read().storage.directories_opened.clone()),
        }
    }
}
