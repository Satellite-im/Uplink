use std::{path::PathBuf, sync::Arc};

use once_cell::sync::Lazy;
use tokio::sync::Mutex;

use crate::state::storage::Storage;

pub enum UploadFileAction<T> {
    Starting(String),
    SizeNotAvailable(String),
    Cancelling,
    UploadFiles(Vec<PathBuf>),
    Uploading((String, String, String)),
    Finishing(PathBuf, bool),
    Finished(T),
    Error,
}
pub struct UploadFileChannel<T> {
    pub tx: tokio::sync::mpsc::UnboundedSender<UploadFileAction<T>>,
    pub rx: Arc<Mutex<tokio::sync::mpsc::UnboundedReceiver<UploadFileAction<T>>>>,
}

pub static UPLOAD_FILE_LISTENER: Lazy<UploadFileChannel<Storage>> = Lazy::new(|| {
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    UploadFileChannel {
        tx,
        rx: Arc::new(Mutex::new(rx)),
    }
});

pub struct CancelUploadChannel<T> {
    pub tx: tokio::sync::mpsc::UnboundedSender<T>,
    pub rx: Arc<Mutex<tokio::sync::mpsc::UnboundedReceiver<T>>>,
}

pub static CANCEL_FILE_UPLOADLISTENER: Lazy<CancelUploadChannel<bool>> = Lazy::new(|| {
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    CancelUploadChannel {
        tx,
        rx: Arc::new(Mutex::new(rx)),
    }
});
