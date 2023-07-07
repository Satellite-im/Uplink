use once_cell::sync::Lazy;
use warp::sync::RwLock;
use wry::webview::FileDropEvent;

pub fn get_drag_event() -> FileDropEvent {
    DRAG_EVENT.read().clone()
}

pub static DRAG_EVENT: Lazy<RwLock<FileDropEvent>> =
    Lazy::new(|| RwLock::new(FileDropEvent::Cancelled));
