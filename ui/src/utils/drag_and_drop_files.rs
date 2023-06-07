use once_cell::sync::Lazy;
use std::path::{Path, PathBuf};
use warp::sync::RwLock;
use wry::webview::FileDropEvent;

static DRAG_EVENT: Lazy<RwLock<FileDropEvent>> =
    Lazy::new(|| RwLock::new(FileDropEvent::Cancelled));

pub fn set_drag_event(new_drag_event: FileDropEvent) {
    *DRAG_EVENT.write() = new_drag_event;
}

pub fn get_drag_event() -> FileDropEvent {
    DRAG_EVENT.read().clone()
}

pub fn verify_if_there_are_valid_paths(files_local_path: &Vec<PathBuf>) -> bool {
    if files_local_path.is_empty() {
        false
    } else {
        files_local_path.first().map_or(false, |path| path.exists())
    }
}

pub fn decoded_pathbufs(paths: Vec<PathBuf>) -> Vec<PathBuf> {
    #[allow(unused_mut)]
    let mut paths = paths;
    #[cfg(target_os = "linux")]
    {
        let decode = |path: &Path| path.as_os_str().to_string_lossy().replace("%20", " ");
        paths = paths
            .iter()
            .map(|p| PathBuf::from(decode(p)))
            .collect::<Vec<PathBuf>>();
    }
    paths
}
