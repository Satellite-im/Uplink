#[cfg(target_os = "linux")]
use std::path::Path;
use std::{ffi::OsStr, path::PathBuf, time::Duration};

use common::{
    language::get_local_text,
    state::{storage::Storage, Action, State, ToastNotification},
    warp_runner::{ConstellationCmd, FileTransferProgress, FileTransferStep, WarpCmd},
    WARP_CMD_CH,
};
use dioxus_core::Scoped;
use dioxus_desktop::DesktopContext;
use dioxus_hooks::{
    to_owned, use_coroutine, use_future, Coroutine, UnboundedReceiver, UseRef, UseSharedState,
    UseState,
};
use futures::{channel::oneshot, StreamExt};
// use nix::sys::statvfs::statvfs;
use tokio::{
    sync::mpsc::{self},
    time::sleep,
};
use wry::webview::FileDropEvent;

use crate::layouts::storage::{ANIMATION_DASH_SCRIPT, FEEDBACK_TEXT_SCRIPT, FILE_NAME_SCRIPT};

use super::{controller::StorageController, ChanCmd, Props, DRAG_EVENT, MAX_LEN_TO_FORMAT_NAME};

pub fn run_verifications_and_update_storage(
    first_render: &UseState<bool>,
    state: &UseSharedState<State>,
    storage_controller: StorageController,
    ch: &Coroutine<ChanCmd>,
) {
    if *first_render.get() && state.read().ui.is_minimal_view() {
        state.write().mutate(Action::SidebarHidden(true));
        first_render.set(false);
    }

    if let Some(storage) = storage_controller.storage_state.get().clone() {
        *(storage_controller.directories_list).write_silent() = storage.directories.clone();
        *(storage_controller.files_list).write_silent() = storage.files.clone();
        *(storage_controller.current_dir).write_silent() = storage.current_dir.clone();
        *(storage_controller.dirs_opened_ref).write_silent() = storage.directories_opened.clone();
        state.write().storage = storage;
        storage_controller.storage_state.set(None);
        ch.send(ChanCmd::GetStorageSize);
    }
}

pub fn allow_drag_event_for_non_macos_systems(
    cx: &Scoped<Props>,
    drag_event: &UseRef<Option<FileDropEvent>>,
    window: &dioxus_desktop::DesktopContext,
    main_script: &str,
    ch: &Coroutine<ChanCmd>,
) {
    use_future(cx, (), |_| {
        #[cfg(not(target_os = "macos"))]
        to_owned![ch, main_script, window, drag_event];
        #[cfg(target_os = "macos")]
        to_owned![ch];
        async move {
            sleep(Duration::from_millis(300)).await;
            ch.send(ChanCmd::GetItemsFromCurrentDirectory);
            // ondragover function from div does not work on windows
            #[cfg(not(target_os = "macos"))]
            loop {
                sleep(Duration::from_millis(100)).await;
                if let FileDropEvent::Hovered { .. } = get_drag_event() {
                    if drag_event.with(|i| i.clone()).is_none() {
                        drag_and_drop_function(&window, &drag_event, main_script.clone(), &ch)
                            .await;
                    }
                }
            }
        }
    });
}

pub fn get_drag_event() -> FileDropEvent {
    DRAG_EVENT.read().clone()
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
    drag_event: &UseRef<Option<FileDropEvent>>,
    main_script: String,
    ch: &Coroutine<ChanCmd>,
) {
    *drag_event.write_silent() = Some(get_drag_event());
    loop {
        let file_drop_event = get_drag_event();
        match file_drop_event {
            FileDropEvent::Hovered { paths, .. } => {
                if verify_if_there_are_valid_paths(&paths) {
                    let mut script = main_script.replace("$IS_DRAGGING", "true");
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
                *drag_event.write_silent() = None;
                let script = main_script.replace("$IS_DRAGGING", "false");
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
