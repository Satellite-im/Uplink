#[cfg(target_os = "linux")]
use std::path::Path;
use std::{ffi::OsStr, path::PathBuf, time::Duration};

use common::{
    language::get_local_text,
    state::{Action, State},
};
use dioxus_core::Scoped;
use dioxus_desktop::DesktopContext;
use dioxus_hooks::{to_owned, use_future, Coroutine, UseRef, UseSharedState};
// use nix::sys::statvfs::statvfs;
use tokio::time::sleep;
use wry::webview::FileDropEvent;

use crate::{
    layouts::storage::presentation::view::{files_page::Props, scripts::*},
    utils::drag_and_drop_files::get_drag_event,
};

use super::{coroutine::ChanCmd, storage_controller::StorageController};

const MAX_LEN_TO_FORMAT_NAME: usize = 15;

pub fn run_verifications_and_update_storage(
    storage_controller: &UseRef<StorageController>,
    state: &UseSharedState<State>,
    ch: &Coroutine<ChanCmd>,
) {
    if storage_controller.with(|i| i.first_render) && state.read().ui.is_minimal_view() {
        state.write().mutate(Action::SidebarHidden(true));
        storage_controller.with_mut(|i| i.first_render = false);
    }

    if storage_controller.write_silent().update_state(state) {
        ch.send(ChanCmd::GetStorageSize);
    }
}

pub fn get_items_from_current_directory(cx: &Scoped<Props>, ch: &Coroutine<ChanCmd>) {
    use_future(cx, (), |_| {
        to_owned![ch];
        async move {
            sleep(Duration::from_millis(300)).await;
            ch.send(ChanCmd::GetItemsFromCurrentDirectory);
        }
    });
}

#[cfg(not(target_os = "macos"))]
pub fn allow_drag_event_for_non_macos_systems(
    cx: &Scoped<Props>,
    controller: &UseRef<StorageController>,
    window: &dioxus_desktop::DesktopContext,
    ch: &Coroutine<ChanCmd>,
) {
    use_future(cx, (), |_| {
        to_owned![ch, window, controller, ch];
        async move {
            // ondragover function from div does not work on windows
            loop {
                sleep(Duration::from_millis(100)).await;
                if let FileDropEvent::Hovered { .. } = get_drag_event() {
                    if controller.with(|i| i.drag_event.clone()).is_none() {
                        drag_and_drop_function(&window, &controller, &ch).await;
                    }
                }
            }
        }
    });
}

pub fn format_item_name(file_name: String) -> String {
    let item = PathBuf::from(&file_name);

    let file_stem = item
        .file_stem()
        .and_then(OsStr::to_str)
        .map(str::to_string)
        .unwrap_or_default();

    file_name
        .get(0..15)
        .map(|x| x.to_string())
        .map(|x| {
            if file_stem.len() > MAX_LEN_TO_FORMAT_NAME {
                format!("{x}...")
            } else {
                x
            }
        })
        .unwrap_or_else(|| file_name.clone())
}

pub async fn drag_and_drop_function(
    window: &DesktopContext,
    controller: &UseRef<StorageController>,
    ch: &Coroutine<ChanCmd>,
) {
    controller.write_silent().drag_event = Some(get_drag_event());
    loop {
        let file_drop_event = get_drag_event();
        match file_drop_event {
            FileDropEvent::Hovered { paths, .. } => {
                if verify_if_there_are_valid_paths(&paths) {
                    let mut script = MAIN_SCRIPT_JS.replace("$IS_DRAGGING", "true");
                    if paths.len() > 1 {
                        script.push_str(&FEEDBACK_TEXT_SCRIPT.replace(
                            "$TEXT",
                            &format!(
                                "{} {}!",
                                paths.len(),
                                get_local_text("files.files-to-upload")
                            ),
                        ));
                    } else {
                        script.push_str(&FEEDBACK_TEXT_SCRIPT.replace(
                            "$TEXT",
                            &format!(
                                "{} {}!",
                                paths.len(),
                                get_local_text("files.one-file-to-upload")
                            ),
                        ));
                    }
                    window.eval(&script);
                }
            }
            FileDropEvent::Dropped { paths, .. } => {
                if verify_if_there_are_valid_paths(&paths) {
                    let new_files_to_upload = decoded_pathbufs(paths);
                    ch.send(ChanCmd::UploadFiles(new_files_to_upload));
                    break;
                }
            }
            _ => {
                controller.write_silent().drag_event = None;
                let script = MAIN_SCRIPT_JS.replace("$IS_DRAGGING", "false");
                window.eval(&script);
                break;
            }
        };
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
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

pub fn format_item_size(item_size: usize) -> String {
    if item_size == 0 {
        return String::from("0 bytes");
    }
    let base_1024: f64 = 1024.0;
    let size_f64: f64 = item_size as f64;

    let i = (size_f64.log10() / base_1024.log10()).floor();
    let size_formatted = size_f64 / base_1024.powf(i);

    let item_size_suffix = ["bytes", "KB", "MB", "GB", "TB"][i as usize];
    let mut size_formatted_string = format!(
        "{size:.*} {size_suffix}",
        1,
        size = size_formatted,
        size_suffix = item_size_suffix
    );
    if size_formatted_string.contains(".0") {
        size_formatted_string = size_formatted_string.replace(".0", "");
    }
    size_formatted_string
}
