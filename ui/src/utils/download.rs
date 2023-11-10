use std::{fs::rename, path::PathBuf};

/// Returns a temporary file for downloads and a handler for when the download finishes
pub fn get_download_path(path: PathBuf) -> (PathBuf, impl Fn()) {
    let mut temp = path.clone();
    temp.as_mut_os_string().push(".updownload");
    let temp2 = temp.clone();
    (temp, move || finish_download(&temp2, &path))
}

fn finish_download(temp: &PathBuf, path: &PathBuf) {
    let _ = rename(temp, path);
}
