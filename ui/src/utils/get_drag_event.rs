use std::path::PathBuf;

use dioxus_desktop::wry::webview::FileDropEvent;
use once_cell::sync::Lazy;
use parking_lot::RwLock;

pub fn get_drag_event() -> FileDropEvent {
    match DRAG_EVENT.read().clone() {
        FileDropEvent::Cancelled => return FileDropEvent::Cancelled,
        FileDropEvent::Hovered { paths, .. } | FileDropEvent::Dropped { paths, .. } => {
            let filtered_paths: Vec<PathBuf> = paths
                .clone()
                .iter()
                .filter(|&path| {
                    let data = path.to_string_lossy().to_string();
                    !(data.contains("image/jpeg;base64") || data.contains("image/png;base64"))
                })
                .cloned()
                .collect();
            if filtered_paths.is_empty() {
                return FileDropEvent::Cancelled;
            }
        }
        _ => return FileDropEvent::Cancelled,
    }
    DRAG_EVENT.read().clone()
}

pub static DRAG_EVENT: Lazy<RwLock<FileDropEvent>> =
    Lazy::new(|| RwLock::new(FileDropEvent::Cancelled));

pub static BLOCK_CANCEL_DRAG_EVENT_FOR_LINUX: Lazy<RwLock<bool>> = Lazy::new(|| RwLock::new(false));
