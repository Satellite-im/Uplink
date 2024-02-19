use std::path::PathBuf;

use futures::{future::BoxFuture, FutureExt};

pub type DownloadComplete = Box<dyn Send + FnOnce(bool) -> BoxFuture<'static, ()>>;

/// Returns a temporary file for downloads and a handler for when the download finishes
/// Passing true indicates the download failed and the file should be deleted
pub fn get_download_path(path: PathBuf) -> (PathBuf, DownloadComplete) {
    let mut temp = path.clone();
    temp.set_extension("updownload");
    let temp2 = temp.clone();
    let t = |err| {
        async move {
            if err {
                let _ = tokio::fs::remove_file(&temp2).await;
            } else if let Err(e) = tokio::fs::rename(&temp2, &path).await {
                log::error!("Unable to rename downloaded file: {e}");
            }
        }
        .boxed()
    };
    (temp, Box::new(t))
}
