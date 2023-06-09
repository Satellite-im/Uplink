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
        decoded_pathbufs(files_local_path.clone())
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

pub fn storage_coroutine<'a>(
    cx: &'a Scoped<'a, Props>,
    state: &UseSharedState<State>,
    storage_state: &'a UseState<Option<Storage>>,
    storage_size: &'a UseRef<(String, String)>,
    main_script: String,
    window: &'a DesktopContext,
    drag_event: &'a UseRef<Option<FileDropEvent>>,
) -> &'a Coroutine<ChanCmd> {
    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<ChanCmd>| {
        to_owned![
            storage_state,
            main_script,
            window,
            drag_event,
            storage_size,
            state
        ];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(cmd) = rx.next().await {
                match cmd {
                    ChanCmd::CreateNewDirectory(directory_name) => {
                        let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();
                        let directory_name2 = directory_name.clone();

                        if let Err(e) = warp_cmd_tx.send(WarpCmd::Constellation(
                            ConstellationCmd::CreateNewDirectory {
                                directory_name,
                                rsp: tx,
                            },
                        )) {
                            log::error!("failed to add new directory {}", e);
                            continue;
                        }

                        let rsp = rx.await.expect("command canceled");

                        match rsp {
                            Ok(_) => {
                                log::info!("New directory added: {}", directory_name2);
                            }
                            Err(e) => {
                                log::error!("failed to add new directory: {}", e);
                                continue;
                            }
                        }
                    }
                    ChanCmd::GetItemsFromCurrentDirectory => {
                        let (tx, rx) = oneshot::channel::<Result<Storage, warp::error::Error>>();

                        if let Err(e) = warp_cmd_tx.send(WarpCmd::Constellation(
                            ConstellationCmd::GetItemsFromCurrentDirectory { rsp: tx },
                        )) {
                            log::error!("failed to get items from current directory {}", e);
                            continue;
                        }

                        let rsp = rx.await.expect("command canceled");
                        match rsp {
                            Ok(storage) => {
                                storage_state.set(Some(storage));
                            }
                            Err(e) => {
                                log::error!("failed to add new directory: {}", e);
                                continue;
                            }
                        }
                    }
                    ChanCmd::OpenDirectory(directory_name) => {
                        let (tx, rx) = oneshot::channel::<Result<Storage, warp::error::Error>>();
                        let directory_name2 = directory_name.clone();

                        if let Err(e) = warp_cmd_tx.send(WarpCmd::Constellation(
                            ConstellationCmd::OpenDirectory {
                                directory_name,
                                rsp: tx,
                            },
                        )) {
                            log::error!("failed to open {directory_name2} directory {}", e);
                            continue;
                        }

                        let rsp = rx.await.expect("command canceled");
                        match rsp {
                            Ok(storage) => {
                                storage_state.set(Some(storage));
                                log::info!("Folder {} opened", directory_name2);
                            }
                            Err(e) => {
                                log::error!("failed to open folder {directory_name2}: {}", e);
                                continue;
                            }
                        }
                    }
                    ChanCmd::BackToPreviousDirectory(directory) => {
                        let (tx, rx) = oneshot::channel::<Result<Storage, warp::error::Error>>();
                        let directory_name = directory.name();

                        if let Err(e) = warp_cmd_tx.send(WarpCmd::Constellation(
                            ConstellationCmd::BackToPreviousDirectory { directory, rsp: tx },
                        )) {
                            log::error!("failed to open directory {}: {}", directory_name, e);
                            continue;
                        }

                        let rsp = rx.await.expect("command canceled");
                        match rsp {
                            Ok(storage) => {
                                storage_state.set(Some(storage));
                                log::info!("Folder {} opened", directory_name);
                            }
                            Err(e) => {
                                log::error!("failed to open directory {}: {}", directory_name, e);
                                continue;
                            }
                        }
                    }
                    ChanCmd::UploadFiles(files_path) => {
                        let mut script = main_script.replace("$IS_DRAGGING", "true");
                        script.push_str(ANIMATION_DASH_SCRIPT);
                        window.eval(&script);

                        let (tx, mut rx) =
                            mpsc::unbounded_channel::<FileTransferProgress<Storage>>();

                        if let Err(e) = warp_cmd_tx.send(WarpCmd::Constellation(
                            ConstellationCmd::UploadFiles {
                                files_path,
                                rsp: tx,
                            },
                        )) {
                            log::error!("failed to upload files {}", e);
                            continue;
                        }
                        while let Some(msg) = rx.recv().await {
                            match msg {
                                FileTransferProgress::Step(steps) => {
                                    match steps {
                                        FileTransferStep::SizeNotAvailable(file_name) => {
                                            state.write().mutate(
                                                common::state::Action::AddToastNotification(
                                                    ToastNotification::init(
                                                        "".into(),
                                                        format!(
                                                            "{} {}",
                                                            get_local_text(
                                                                "files.no-size-available"
                                                            ),
                                                            file_name
                                                        ),
                                                        None,
                                                        3,
                                                    ),
                                                ),
                                            );
                                            sleep(Duration::from_millis(1000)).await;
                                        }
                                        FileTransferStep::Start(name) => {
                                            let file_name_formatted = format_item_name(name);
                                            let script = FILE_NAME_SCRIPT
                                                .replace("$FILE_NAME", &file_name_formatted);
                                            window.eval(&script);
                                            sleep(Duration::from_millis(100)).await;
                                        }
                                        FileTransferStep::DuplicateName(duplicate_name_step) => {
                                            match duplicate_name_step {
                                                None => {
                                                    let script = FEEDBACK_TEXT_SCRIPT.replace(
                                                        "$TEXT",
                                                        &get_local_text(
                                                            "files.renaming-duplicated",
                                                        ),
                                                    );
                                                    window.eval(&script);
                                                }
                                                Some(name) => {
                                                    let file_name_formatted =
                                                        format_item_name(name);
                                                    let script = FILE_NAME_SCRIPT.replace(
                                                        "$FILE_NAME",
                                                        &file_name_formatted,
                                                    );
                                                    window.eval(&script);
                                                }
                                            }
                                            sleep(Duration::from_millis(200)).await;
                                        }
                                        FileTransferStep::Upload(progress) => {
                                            let script = FEEDBACK_TEXT_SCRIPT.replace(
                                                "$TEXT",
                                                &format!(
                                                    "{} {}",
                                                    progress,
                                                    get_local_text("files.uploaded")
                                                ),
                                            );
                                            window.eval(&script);
                                            sleep(Duration::from_millis(3)).await;
                                        }
                                        FileTransferStep::Thumbnail(thumb_type) => {
                                            match thumb_type {
                                                Some(_) => {
                                                    let script = FEEDBACK_TEXT_SCRIPT.replace(
                                                        "$TEXT",
                                                        &get_local_text("files.thumbnail-uploaded"),
                                                    );
                                                    window.eval(&script);
                                                }
                                                None => {
                                                    let script = FEEDBACK_TEXT_SCRIPT.replace(
                                                        "$TEXT",
                                                        &get_local_text("files.no-thumbnail"),
                                                    );
                                                    window.eval(&script);
                                                }
                                            }
                                            sleep(Duration::from_millis(200)).await;
                                        }
                                    };
                                }
                                FileTransferProgress::Finished(storage) => {
                                    *drag_event.write_silent() = None;
                                    let mut script = main_script.replace("$IS_DRAGGING", "false");
                                    script.push_str(&FEEDBACK_TEXT_SCRIPT.replace("$TEXT", ""));
                                    script.push_str(&FILE_NAME_SCRIPT.replace("$FILE_NAME", ""));
                                    script.push_str(&ANIMATION_DASH_SCRIPT.replace("0.5s", "0s"));
                                    window.eval(&script);
                                    storage_state.set(Some(storage));
                                    break;
                                }
                                FileTransferProgress::Error(_) => {
                                    *drag_event.write_silent() = None;
                                    let mut script = main_script.replace("$IS_DRAGGING", "false");
                                    script.push_str(&FEEDBACK_TEXT_SCRIPT.replace("$TEXT", ""));
                                    script.push_str(&FILE_NAME_SCRIPT.replace("$FILE_NAME", ""));
                                    script.push_str(&ANIMATION_DASH_SCRIPT.replace("0.5s", "0s"));
                                    window.eval(&script);
                                    break;
                                }
                            }
                        }
                    }
                    ChanCmd::DownloadFile {
                        file_name,
                        local_path_to_save_file,
                    } => {
                        let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();

                        if let Err(e) = warp_cmd_tx.send(WarpCmd::Constellation(
                            ConstellationCmd::DownloadFile {
                                file_name,
                                local_path_to_save_file,
                                rsp: tx,
                            },
                        )) {
                            log::error!("failed to download file {}", e);
                            continue;
                        }

                        let rsp = rx.await.expect("command canceled");

                        if let Err(error) = rsp {
                            log::error!("failed to download file: {}", error);
                            continue;
                        }
                    }
                    ChanCmd::RenameItem { old_name, new_name } => {
                        let (tx, rx) = oneshot::channel::<Result<Storage, warp::error::Error>>();

                        if let Err(e) =
                            warp_cmd_tx.send(WarpCmd::Constellation(ConstellationCmd::RenameItem {
                                old_name,
                                new_name,
                                rsp: tx,
                            }))
                        {
                            log::error!("failed to rename item {}", e);
                            continue;
                        }

                        let rsp = rx.await.expect("command canceled");
                        match rsp {
                            Ok(storage) => {
                                storage_state.set(Some(storage));
                            }
                            Err(e) => {
                                log::error!(
                                    "failed to update uplink storage with renamed item: {}",
                                    e
                                );
                                continue;
                            }
                        }
                    }
                    ChanCmd::DeleteItems(item) => {
                        let (tx, rx) = oneshot::channel::<Result<Storage, warp::error::Error>>();

                        if let Err(e) = warp_cmd_tx.send(WarpCmd::Constellation(
                            ConstellationCmd::DeleteItems {
                                item: item.clone(),
                                rsp: tx,
                            },
                        )) {
                            log::error!("failed to delete items {}, item {:?}", e, item.name());
                            continue;
                        }

                        let rsp = rx.await.expect("command canceled");
                        match rsp {
                            Ok(storage) => {
                                storage_state.set(Some(storage));
                            }
                            Err(e) => {
                                log::error!("failed to delete items {}, item {:?}", e, item.name());
                                continue;
                            }
                        }
                    }
                    ChanCmd::GetStorageSize => {
                        let (tx, rx) =
                            oneshot::channel::<Result<(usize, usize), warp::error::Error>>();

                        if let Err(e) = warp_cmd_tx.send(WarpCmd::Constellation(
                            ConstellationCmd::GetStorageSize { rsp: tx },
                        )) {
                            log::error!("failed to get storage size: {}", e);
                            continue;
                        }

                        let rsp = rx.await.expect("command canceled");
                        match rsp {
                            Ok((max_size, current_size)) => {
                                let max_storage_size = format_item_size(max_size);
                                let current_storage_size = format_item_size(current_size);
                                storage_size
                                    .with_mut(|i| *i = (max_storage_size, current_storage_size));
                            }
                            Err(e) => {
                                storage_size.with_mut(|i| {
                                    *i = (
                                        get_local_text("files.no-data-available"),
                                        get_local_text("files.no-data-available"),
                                    )
                                });
                                log::error!("failed to get storage size: {}", e);
                                continue;
                            }
                        }
                    }
                }
            }
        }
    });
    ch
}
