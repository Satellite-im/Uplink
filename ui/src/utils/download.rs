use std::path::PathBuf;

use futures::{future::BoxFuture, FutureExt};

/// Returns a temporary file for downloads and a handler for when the download finishes
pub fn get_download_path(path: PathBuf) -> (PathBuf, BoxFuture<'static, ()>) {
    let mut temp = path.clone();
    temp.set_extension(".updownload");
    let temp2 = temp.clone();
    (
        temp,
        async move {
            if let Err(e) = tokio::fs::rename(&temp2, &path).await {
                log::error!("Unable to rename downloaded file: {e}");
            }
        }
        .boxed(),
    )
}
