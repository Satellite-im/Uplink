use std::path::PathBuf;

/// It will work to load local files in img or video tags, but will ignore drive
const PREFIX_TO_WORK_ON_WINDOWS_OS: &str = "http://dioxus.";

/// This function is used to treat local file path if it needs
/// to be loaded in img or video tags for example
pub fn get_fixed_path_to_load_local_file(path: PathBuf) -> String {
    if !cfg!(target_os = "windows") {
        path.to_string_lossy().to_string()
    } else {
        format!(
            "{}{}",
            PREFIX_TO_WORK_ON_WINDOWS_OS,
            path.to_string_lossy().to_string().replace("\\", "/")
        )
    }
}
