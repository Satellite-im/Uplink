#[cfg(target_os = "linux")]
use std::path::Path;
use std::path::PathBuf;

pub fn verify_paths(paths: &Vec<PathBuf>) -> bool {
    if paths.is_empty() {
        false
    } else {
        decoded_pathbufs(paths.clone())
            .first()
            .map_or(false, |path| path.exists())
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
