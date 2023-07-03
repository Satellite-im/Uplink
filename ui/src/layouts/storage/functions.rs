use std::{ffi::OsStr, path::PathBuf, time::Duration};

use common::{
    language::get_local_text,
    state::{storage::Storage, Action, State, ToastNotification},
    upload_file_channel::{UploadFileAction, UPLOAD_FILE_LISTENER},
    warp_runner::{ConstellationCmd, WarpCmd},
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
use tokio::time::sleep;

use crate::components::files::upload_progress_bar;

use super::{controller::StorageController, ChanCmd, Props, MAX_LEN_TO_FORMAT_NAME};

pub fn run_verifications_and_update_storage(
    first_render: &UseState<bool>,
    state: &UseSharedState<State>,
    storage_controller: StorageController,
    storage_size: &UseRef<(String, String)>,
    files_in_queue_to_upload: &UseRef<Vec<PathBuf>>,
) {
    if *first_render.get() && state.read().ui.is_minimal_view() {
        state.write().mutate(Action::SidebarHidden(true));
        first_render.set(false);
    }

    if state.read().storage.files_in_queue_to_upload.len() != files_in_queue_to_upload.read().len()
    {
        state.write_silent().storage.files_in_queue_to_upload =
            files_in_queue_to_upload.read().clone();
    }

    if let Some(storage) = storage_controller.storage_state.get().clone() {
        *(storage_controller.directories_list).write_silent() = storage.directories.clone();
        *(storage_controller.files_list).write_silent() = storage.files.clone();
        *(storage_controller.current_dir).write_silent() = storage.current_dir.clone();
        *(storage_controller.dirs_opened_ref).write_silent() = storage.directories_opened.clone();
        *storage_size.write_silent() = (
            format_item_size(storage.max_size),
            format_item_size(storage.current_size),
        );
        state.write().storage = Storage {
            files_in_queue_to_upload: files_in_queue_to_upload.read().clone(),
            ..storage
        };
        storage_controller.storage_state.set(None);
    }
}

pub fn get_items_from_current_directory(cx: &Scoped<Props>, ch: &Coroutine<ChanCmd>) {
    use_future(cx, (), |_| {
        to_owned![ch];
        async move {
            sleep(Duration::from_secs(1)).await;
            ch.send(ChanCmd::GetItemsFromCurrentDirectory);
        }
    });
}

#[cfg(not(target_os = "macos"))]
pub fn allow_drag_event_for_non_macos_systems(
    cx: &Scoped<Props>,
    drag_event: &UseRef<Option<FileDropEvent>>,
    window: &dioxus_desktop::DesktopContext,
    main_script: &str,
    ch: &Coroutine<ChanCmd>,
) {
    use_future(cx, (), |_| {
        to_owned![ch, main_script, window, drag_event];
        async move {
            // ondragover function from div does not work on windows
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

pub fn format_item_name(file_name: String) -> String {
    let item = PathBuf::from(&file_name);

    let file_stem = item
        .file_stem()
        .and_then(OsStr::to_str)
        .map(str::to_string)
        .unwrap_or_default();

    file_name
        .get(0..64)
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

pub fn init_coroutine<'a>(
    cx: &'a Scoped<'a, Props>,
    storage_state: &'a UseState<Option<Storage>>,
) -> &'a Coroutine<ChanCmd> {
    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<ChanCmd>| {
        to_owned![storage_state];
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
                        if let Err(e) = warp_cmd_tx.send(WarpCmd::Constellation(
                            ConstellationCmd::UploadFiles { files_path },
                        )) {
                            log::error!("failed to upload files {}", e);
                            continue;
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
                }
            }
        }
    });
    ch
}

pub fn start_upload_file_listener(
    cx: &Scoped<Props>,
    files_been_uploaded: &UseRef<bool>,
    window: &DesktopContext,
    storage_state: &UseState<Option<Storage>>,
    state: &UseSharedState<State>,
    first_render: &UseState<bool>,
    files_in_queue_to_upload: &UseRef<Vec<PathBuf>>,
    disable_cancel_upload_button: &UseRef<bool>,
) {
    use_future(cx, (), |_| {
        to_owned![
            files_been_uploaded,
            window,
            storage_state,
            state,
            first_render,
            files_in_queue_to_upload,
            disable_cancel_upload_button
        ];
        async move {
            let listener_channel = UPLOAD_FILE_LISTENER.rx.clone();
            log::trace!("starting upload file action listener");
            let mut ch = listener_channel.lock().await;
            loop {
                if let Ok(cmd) = ch.try_recv() {
                    match cmd {
                        UploadFileAction::SizeNotAvailable(file_name) => {
                            state
                                .write()
                                .mutate(common::state::Action::AddToastNotification(
                                    ToastNotification::init(
                                        "".into(),
                                        format!(
                                            "{} {}",
                                            get_local_text("files.no-size-available"),
                                            file_name
                                        ),
                                        None,
                                        3,
                                    ),
                                ));
                        }
                        UploadFileAction::Starting(filename) => {
                            *files_been_uploaded.write_silent() = true;
                            upload_progress_bar::update_filename(&window, filename);
                            sleep(Duration::from_millis(500)).await;
                        }
                        UploadFileAction::Cancelling => {
                            *disable_cancel_upload_button.write_silent() = true;
                            if !files_in_queue_to_upload.read().is_empty() {
                                files_in_queue_to_upload.write().remove(0);
                                upload_progress_bar::update_files_queue_len(
                                    &window,
                                    files_in_queue_to_upload.read().len(),
                                );
                            }
                            upload_progress_bar::change_progress_description(
                                &window,
                                get_local_text("files.cancelling-upload"),
                            );
                            sleep(Duration::from_millis(500)).await;
                            if files_in_queue_to_upload.read().is_empty() {
                                *files_been_uploaded.write_silent() = false;
                            }
                        }
                        UploadFileAction::Uploading((progress, msg, filename)) => {
                            if !*files_been_uploaded.read() && *first_render.current() {
                                *files_been_uploaded.write() = true;
                            }
                            if disable_cancel_upload_button.with(|i| *i) {
                                disable_cancel_upload_button.with_mut(|i| *i = false);
                            }
                            upload_progress_bar::update_filename(&window, filename);
                            upload_progress_bar::update_files_queue_len(
                                &window,
                                files_in_queue_to_upload.read().len(),
                            );
                            upload_progress_bar::change_progress_percentage(
                                &window,
                                progress.clone(),
                            );
                            upload_progress_bar::change_progress_description(&window, msg);
                        }
                        UploadFileAction::Finishing(msg) => {
                            *files_been_uploaded.write_silent() = true;
                            if !files_in_queue_to_upload.read().is_empty() {
                                files_in_queue_to_upload.write().remove(0);
                                upload_progress_bar::update_files_queue_len(
                                    &window,
                                    files_in_queue_to_upload.read().len(),
                                );
                            }
                            upload_progress_bar::change_progress_percentage(&window, msg);
                            upload_progress_bar::change_progress_description(
                                &window,
                                get_local_text("files.finishing-upload"),
                            );
                        }
                        UploadFileAction::Finished(storage) => {
                            if files_in_queue_to_upload.read().is_empty() {
                                *files_been_uploaded.write_silent() = false;
                            }
                            upload_progress_bar::change_progress_description(
                                &window,
                                "Finished".into(),
                            );
                            storage_state.set(Some(storage));
                        }
                        UploadFileAction::Error(_) => {
                            if !files_in_queue_to_upload.read().is_empty() {
                                files_in_queue_to_upload.write().remove(0);
                                upload_progress_bar::update_files_queue_len(
                                    &window,
                                    files_in_queue_to_upload.read().len(),
                                );
                            }
                            upload_progress_bar::change_progress_percentage(&window, "0%".into());
                            upload_progress_bar::change_progress_description(
                                &window,
                                get_local_text("files.error-to-upload"),
                            );
                        }
                    }
                }
                if *files_been_uploaded.read() {
                    sleep(Duration::from_millis(5)).await;
                } else {
                    sleep(Duration::from_millis(300)).await;
                }
            }
        }
    });
}
