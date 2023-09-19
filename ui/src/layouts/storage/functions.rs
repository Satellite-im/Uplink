#[cfg(not(target_os = "macos"))]
use crate::utils::get_drag_event;
use common::{
    language::{get_local_text, get_local_text_with_args},
    state::{storage::Storage, Action, State, ToastNotification},
    upload_file_channel::{UploadFileAction, UPLOAD_FILE_LISTENER},
    warp_runner::{ConstellationCmd, WarpCmd},
    WARP_CMD_CH,
};
use dioxus::prelude::{use_eval, EvalError, UseEval};
use dioxus_core::ScopeState;
#[cfg(not(target_os = "macos"))]
use dioxus_desktop::wry::webview::FileDropEvent;
use dioxus_desktop::DesktopContext;
use dioxus_hooks::{
    to_owned, use_coroutine, use_future, Coroutine, UnboundedReceiver, UseRef, UseSharedState,
};
use futures::{channel::oneshot, StreamExt};
use rfd::FileDialog;
use std::{ffi::OsStr, path::PathBuf, rc::Rc, time::Duration};
use tokio::time::sleep;
use warp::constellation::{directory::Directory, item::Item};

use crate::components::files::upload_progress_bar;

use super::files_layout::controller::{StorageController, UploadFileController};

pub type UseEvalFn = Rc<dyn Fn(&str) -> Result<UseEval, EvalError>>;

static ALLOW_FOLDER_NAVIGATION: &str = r#"
    var folders_element = document.getElementById('files-list');
    folders_element.style.pointerEvents = '$POINTER_EVENT';
    folders_element.style.opacity = '$OPACITY';
    var folders_breadcumbs_element = document.getElementById('files-breadcrumbs');
    folders_breadcumbs_element.style.pointerEvents = '$POINTER_EVENT';
    folders_breadcumbs_element.style.opacity = '$OPACITY';
"#;

const MAX_LEN_TO_FORMAT_NAME: usize = 64;

pub fn run_verifications_and_update_storage(
    state: &UseSharedState<State>,
    controller: &UseRef<StorageController>,
    files_in_queue_to_upload: &UseRef<Vec<PathBuf>>,
) {
    if controller.read().first_render && state.read().ui.is_minimal_view() {
        state.write_silent().mutate(Action::SidebarHidden(true));
        controller.with_mut(|i| i.first_render = false);
    }

    if state.read().storage.files_in_queue_to_upload.len() != files_in_queue_to_upload.read().len()
    {
        state.write_silent().storage.files_in_queue_to_upload =
            files_in_queue_to_upload.read().clone();
    }
    if let Some(storage) = controller.write_silent().update_state() {
        state.write().storage = Storage {
            files_in_queue_to_upload: files_in_queue_to_upload.read().clone(),
            ..storage
        };
    }
}

pub fn get_items_from_current_directory(cx: &ScopeState, ch: &Coroutine<ChanCmd>) {
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
    are_files_hovering_app: &UseRef<bool>,
) {
    use_future(cx, (), |_| {
        to_owned![are_files_hovering_app];
        async move {
            // ondragover function from div does not work on windows
            loop {
                sleep(Duration::from_millis(100)).await;
                if let FileDropEvent::Hovered { .. } = get_drag_event::get_drag_event() {
                    if are_files_hovering_app.with(|i| !(*i)) {
                        are_files_hovering_app.with_mut(|i| *i = true);
                    };
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

pub fn download_file(file_name: &str, ch: &Coroutine<ChanCmd>) {
    let file_extension = std::path::Path::new(&file_name)
        .extension()
        .and_then(OsStr::to_str)
        .map(|s| s.to_string())
        .unwrap_or_default();
    let file_stem = PathBuf::from(&file_name)
        .file_stem()
        .and_then(OsStr::to_str)
        .map(str::to_string)
        .unwrap_or_default();
    let file_path_buf = match FileDialog::new()
        .set_directory(".")
        .set_file_name(&file_stem)
        .add_filter("", &[&file_extension])
        .save_file()
    {
        Some(path) => path,
        None => return,
    };
    ch.send(ChanCmd::DownloadFile {
        file_name: file_name.to_string(),
        local_path_to_save_file: file_path_buf,
    });
}

pub fn add_files_in_queue_to_upload(
    files_in_queue_to_upload: &UseRef<Vec<PathBuf>>,
    files_path: Vec<PathBuf>,
    eval: &UseEvalFn,
) {
    let tx_upload_file = UPLOAD_FILE_LISTENER.tx.clone();
    allow_folder_navigation(eval, false);
    files_in_queue_to_upload
        .write_silent()
        .extend(files_path.clone());
    let _ = tx_upload_file.send(UploadFileAction::UploadFiles(files_path));
}

pub fn use_allow_block_folder_nav(
    cx: &ScopeState,
    files_in_queue_to_upload: &UseRef<Vec<PathBuf>>,
) {
    let eval: &UseEvalFn = use_eval(cx);

    // Block directories navigation if there is a file been uploaded
    // use_future here to verify before render elements on first render
    use_future(cx, (), |_| {
        to_owned![eval, files_in_queue_to_upload];
        async move {
            allow_folder_navigation(&eval, files_in_queue_to_upload.read().is_empty());
        }
    });
    // This is to run on all re-renders
    allow_folder_navigation(eval, files_in_queue_to_upload.read().is_empty());
}

pub fn allow_folder_navigation(eval: &UseEvalFn, allow_navigation: bool) {
    let new_script = if allow_navigation {
        ALLOW_FOLDER_NAVIGATION
            .replace("$POINTER_EVENT", "")
            .replace("$OPACITY", "1")
    } else {
        ALLOW_FOLDER_NAVIGATION
            .replace("$POINTER_EVENT", "none")
            .replace("$OPACITY", "0.5")
    };

    _ = eval(&new_script);
}

pub enum ChanCmd {
    GetItemsFromCurrentDirectory,
    CreateNewDirectory(String),
    OpenDirectory(String),
    BackToPreviousDirectory(Directory),
    DownloadFile {
        file_name: String,
        local_path_to_save_file: PathBuf,
    },
    RenameItem {
        old_name: String,
        new_name: String,
    },
    DeleteItems(Item),
}

pub fn init_coroutine<'a>(
    cx: &'a ScopeState,
    controller: &'a UseRef<StorageController>,
) -> &'a Coroutine<ChanCmd> {
    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<ChanCmd>| {
        to_owned![controller];
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
                                controller.with_mut(|i| i.storage_state = Some(storage));
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
                                controller.with_mut(|i| i.storage_state = Some(storage));
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
                                controller.with_mut(|i| i.storage_state = Some(storage));
                                log::info!("Folder {} opened", directory_name);
                            }
                            Err(e) => {
                                log::error!("failed to open directory {}: {}", directory_name, e);
                                continue;
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
                                controller.with_mut(|i| i.storage_state = Some(storage));
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
                                controller.with_mut(|i| i.storage_state = Some(storage));
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

/// Upload files has many states to manage
/// 1. It is necessary to check if any file is being uploaded, hence the use of `use_future`.
/// 2. It was necessary to use the global channel to send the command to upload the files,
/// to fix a specific behavior (when the user leaves the page, returns,
/// and tries to upload a second file, then leaves and returns again,
/// it was not possible to cancel that upload in the coroutine).
pub fn start_upload_file_listener(
    cx: &ScopeState,
    window: &DesktopContext,
    state: &UseSharedState<State>,
    controller: &UseRef<StorageController>,
    upload_file_controller: UploadFileController,
) {
    let files_been_uploaded = upload_file_controller.files_been_uploaded.clone();
    let files_in_queue_to_upload = upload_file_controller.files_in_queue_to_upload.clone();
    let disable_cancel_upload_button = upload_file_controller.disable_cancel_upload_button.clone();
    use_future(cx, (), |_| {
        to_owned![
            window,
            state,
            controller,
            files_been_uploaded,
            files_in_queue_to_upload,
            disable_cancel_upload_button
        ];
        async move {
            let listener_channel = UPLOAD_FILE_LISTENER.rx.clone();
            log::trace!("starting upload file action listener");
            let mut ch = listener_channel.lock().await;
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(cmd) = ch.recv().await {
                match cmd {
                    UploadFileAction::UploadFiles(files_path) => {
                        if let Err(e) = warp_cmd_tx.send(WarpCmd::Constellation(
                            ConstellationCmd::UploadFiles { files_path },
                        )) {
                            log::error!("failed to upload files {}", e);
                            continue;
                        }
                    }
                    UploadFileAction::SizeNotAvailable(file_name) => {
                        if !files_in_queue_to_upload.read().is_empty() {
                            files_in_queue_to_upload.with_mut(|i| i.remove(0));
                            upload_progress_bar::update_files_queue_len(
                                &window,
                                files_in_queue_to_upload.read().len(),
                            );
                        }
                        state
                            .write()
                            .mutate(common::state::Action::AddToastNotification(
                                ToastNotification::init(
                                    "".into(),
                                    get_local_text_with_args(
                                        "files.no-size-available",
                                        vec![("file", file_name.into())],
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
                            files_in_queue_to_upload.with_mut(|i| i.remove(0));
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
                        if !*files_been_uploaded.read() && controller.read().first_render {
                            files_been_uploaded.with_mut(|i| *i = true);
                        }
                        if *disable_cancel_upload_button.read() && !progress.contains("100") {
                            disable_cancel_upload_button.with_mut(|i| *i = false)
                        } else if !(*disable_cancel_upload_button.read())
                            && progress.contains("100")
                        {
                            disable_cancel_upload_button.with_mut(|i| *i = true)
                        }
                        upload_progress_bar::update_filename(&window, filename);
                        upload_progress_bar::update_files_queue_len(
                            &window,
                            files_in_queue_to_upload.read().len(),
                        );
                        upload_progress_bar::change_progress_percentage(&window, progress.clone());
                        upload_progress_bar::change_progress_description(&window, msg);
                    }
                    UploadFileAction::Finishing => {
                        *files_been_uploaded.write_silent() = true;
                        if !files_in_queue_to_upload.read().is_empty() {
                            files_in_queue_to_upload.with_mut(|i| i.remove(0));
                            upload_progress_bar::update_files_queue_len(
                                &window,
                                files_in_queue_to_upload.read().len(),
                            );
                        }
                        upload_progress_bar::change_progress_percentage(&window, "100%".into());
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
                            get_local_text("files.finishing-upload"),
                        );
                        controller.with_mut(|i| i.storage_state = Some(storage));
                    }
                    UploadFileAction::Error => {
                        if !files_in_queue_to_upload.read().is_empty() {
                            files_in_queue_to_upload.with_mut(|i| i.remove(0));
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
        }
    });
}
