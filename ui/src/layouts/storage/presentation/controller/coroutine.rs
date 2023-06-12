use std::{path::PathBuf, time::Duration};

use common::{
    language::get_local_text,
    state::{State, ToastNotification},
    warp_runner::{FileTransferProgress, FileTransferStep},
};

use dioxus_core::ScopeState;
use dioxus_desktop::DesktopContext;
use dioxus_hooks::{to_owned, use_coroutine, Coroutine, UnboundedReceiver, UseRef, UseSharedState};
use futures::StreamExt;
use tokio::time::sleep;
use warp::constellation::{directory::Directory, item::Item};

use crate::layouts::storage::{
    domain::repository::StorageRepository,
    presentation::{
        controller::events,
        view::scripts::{
            ANIMATION_DASH_SCRIPT, FEEDBACK_TEXT_SCRIPT, FILE_NAME_SCRIPT, MAIN_SCRIPT_JS,
        },
    },
};

use super::controller::StorageController;

pub enum ChanCmd {
    GetItemsFromCurrentDirectory,
    CreateNewDirectory(String),
    OpenDirectory(String),
    BackToPreviousDirectory(Directory),
    UploadFiles(Vec<PathBuf>),
    DownloadFile {
        file_name: String,
        local_path_to_save_file: PathBuf,
    },
    RenameItem {
        old_name: String,
        new_name: String,
    },
    DeleteItems(Item),
    GetStorageSize,
}

pub fn init_coroutine<'a>(
    cx: &'a ScopeState,
    state: &'a UseSharedState<State>,
    window: &'a DesktopContext,
    controller: &UseRef<StorageController>,
) -> &'a Coroutine<ChanCmd> {
    let repository = StorageRepository::new();
    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<ChanCmd>| {
        to_owned![window, state, controller, repository];
        async move {
            while let Some(cmd) = rx.next().await {
                match cmd {
                    ChanCmd::CreateNewDirectory(directory_name) => {
                        let directory_name_clone = directory_name.clone();
                        match repository.create_new_directory(directory_name).await {
                            Ok(()) => {
                                log::info!("New directory added: {}", directory_name_clone)
                            }
                            Err(_) => continue,
                        }
                    }
                    ChanCmd::GetItemsFromCurrentDirectory => {
                        match repository.get_items_from_current_directory().await {
                            Ok(storage) => controller.with_mut(|i| i.storage_state = Some(storage)),
                            Err(_) => continue,
                        }
                    }
                    ChanCmd::OpenDirectory(directory_name) => {
                        match repository.open_directory(directory_name).await {
                            Ok(storage) => controller.with_mut(|i| i.storage_state = Some(storage)),
                            Err(_) => continue,
                        }
                    }
                    ChanCmd::BackToPreviousDirectory(directory) => {
                        match repository.back_to_previous_directory(directory).await {
                            Ok(storage) => controller.with_mut(|i| i.storage_state = Some(storage)),
                            Err(_) => continue,
                        }
                    }
                    ChanCmd::DownloadFile {
                        file_name,
                        local_path_to_save_file,
                    } => {
                        let file_name_clone = file_name.clone();
                        match repository
                            .download_file(file_name, local_path_to_save_file)
                            .await
                        {
                            Ok(()) => log::info!("File downloaded: {}", file_name_clone),
                            Err(_) => continue,
                        }
                    }
                    ChanCmd::RenameItem { old_name, new_name } => {
                        match repository.rename_item(old_name, new_name).await {
                            Ok(storage) => controller.with_mut(|i| i.storage_state = Some(storage)),
                            Err(_) => continue,
                        }
                    }
                    ChanCmd::DeleteItems(item) => match repository.delete_item(item).await {
                        Ok(storage) => controller.with_mut(|i| i.storage_state = Some(storage)),
                        Err(_) => continue,
                    },
                    ChanCmd::GetStorageSize => match repository.get_storage_size().await {
                        Ok((max_size, current_size)) => {
                            let max_storage_size = events::format_item_size(max_size);
                            let current_storage_size = events::format_item_size(current_size);

                            controller.with_mut(|i| {
                                i.storage_size = (max_storage_size, current_storage_size)
                            });
                        }
                        Err(e) => {
                            controller.with_mut(|i| {
                                i.storage_size = (
                                    get_local_text("files.no-data-available"),
                                    get_local_text("files.no-data-available"),
                                )
                            });
                            log::error!("failed to get storage size: {}", e);
                            continue;
                        }
                    },
                    ChanCmd::UploadFiles(files_path) => {
                        let mut script = MAIN_SCRIPT_JS.replace("$IS_DRAGGING", "true");
                        script.push_str(ANIMATION_DASH_SCRIPT);
                        window.eval(&script);

                        let mut rx = match repository.upload_files(files_path).await {
                            Ok(rx) => rx,
                            Err(_) => continue,
                        };

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
                                            let file_name_formatted =
                                                events::format_item_name(name);
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
                                                        events::format_item_name(name);
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
                                    controller.write_silent().drag_event = None;
                                    let mut script =
                                        MAIN_SCRIPT_JS.replace("$IS_DRAGGING", "false");
                                    script.push_str(&FEEDBACK_TEXT_SCRIPT.replace("$TEXT", ""));
                                    script.push_str(&FILE_NAME_SCRIPT.replace("$FILE_NAME", ""));
                                    script.push_str(&ANIMATION_DASH_SCRIPT.replace("0.5s", "0s"));
                                    window.eval(&script);
                                    controller.with_mut(|i| i.storage_state = Some(storage));
                                    break;
                                }
                                FileTransferProgress::Error(_) => {
                                    controller.write_silent().drag_event = None;
                                    let mut script =
                                        MAIN_SCRIPT_JS.replace("$IS_DRAGGING", "false");
                                    script.push_str(&FEEDBACK_TEXT_SCRIPT.replace("$TEXT", ""));
                                    script.push_str(&FILE_NAME_SCRIPT.replace("$FILE_NAME", ""));
                                    script.push_str(&ANIMATION_DASH_SCRIPT.replace("0.5s", "0s"));
                                    window.eval(&script);
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        }
    });
    ch
}
