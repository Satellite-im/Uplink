#[allow(unused_imports)]
use std::path::Path;
use std::path::PathBuf;
use std::time::Duration;
use std::{fs, io};

use common::icons::outline::Shape as Icon;
use common::language::get_local_text;
use common::state::{ui, Action, State, ToastNotification};
use common::upload_file_channel::CANCEL_FILE_UPLOADLISTENER;
use common::warp_runner::{RayGunCmd, WarpCmd};
use common::{STATIC_ARGS, WARP_CMD_CH};
use dioxus::prelude::*;
use dioxus_desktop::use_window;
use dioxus_router::prelude::use_navigator;
use futures::channel::oneshot;
use kit::elements::label::Label;
use kit::{
    elements::{
        button::Button,
        tooltip::{ArrowPosition, Tooltip},
        Appearance,
    },
    layout::topbar::Topbar,
};
use rfd::FileDialog;
use uuid::Uuid;
use warp::raygun::Location;

pub mod controller;
pub mod file_modal;

use crate::components::files::upload_progress_bar::UploadProgressBar;
use crate::components::paste_files_with_shortcut;
use crate::layouts::chats::ChatSidebar;
use crate::layouts::slimbar::SlimbarLayout;
use crate::layouts::storage::files_layout::file_modal::get_file_modal;
use crate::layouts::storage::send_files_layout::modal::SendFilesLayoutModal;
use crate::layouts::storage::send_files_layout::SendFilesStartLocation;
use crate::layouts::storage::shared_component::{FilesAndFolders, FilesBreadcumbs};

use self::controller::{StorageController, UploadFileController};

use super::functions::{self, ChanCmd, UseEvalFn};

#[allow(non_snake_case)]
pub fn FilesLayout(cx: Scope<'_>) -> Element<'_> {
    let state = use_shared_state::<State>(cx)?;
    state.write_silent().ui.current_layout = ui::Layout::Storage;
    let storage_controller = StorageController::new(cx, state);
    let upload_file_controller = UploadFileController::new(cx, state.clone());
    let window = use_window(cx);
    let files_in_queue_to_upload = upload_file_controller.files_in_queue_to_upload.clone();
    let files_been_uploaded = upload_file_controller.files_been_uploaded.clone();
    let send_files_from_storage = use_state(cx, || false);
    let files_pre_selected_to_send: &UseRef<Vec<Location>> = use_ref(cx, Vec::new);
    let _router = use_navigator(cx);
    let eval: &UseEvalFn = use_eval(cx);
    let show_slimbar = state.read().show_slimbar() & !state.read().ui.is_minimal_view();

    functions::use_allow_block_folder_nav(cx, &files_in_queue_to_upload);

    let ch: &Coroutine<ChanCmd> = functions::init_coroutine(cx, storage_controller, state);

    use_future(cx, (), |_| {
        to_owned![files_been_uploaded, files_in_queue_to_upload];
        async move {
            // Remove load progress bar if anythings goes wrong
            loop {
                if files_in_queue_to_upload.read().is_empty() && *files_been_uploaded.read() {
                    *files_been_uploaded.write() = false;
                }
                tokio::time::sleep(Duration::from_secs(2)).await;
            }
        }
    });

    functions::run_verifications_and_update_storage(
        state,
        storage_controller,
        upload_file_controller
            .files_in_queue_to_upload
            .read()
            .clone(),
    );

    functions::get_items_from_current_directory(cx, ch);

    #[cfg(not(target_os = "macos"))]
    functions::allow_drag_event_for_non_macos_systems(
        cx,
        upload_file_controller.are_files_hovering_app,
    );
    functions::start_upload_file_listener(
        cx,
        window,
        state,
        storage_controller,
        upload_file_controller.clone(),
    );

    let tx_cancel_file_upload = CANCEL_FILE_UPLOADLISTENER.tx.clone();

    cx.render(rsx!(
        if state.read().ui.metadata.focused  {
            rsx!(paste_files_with_shortcut::PasteFilesShortcut {
                on_paste: move |files_local_path| {
                    functions::add_files_in_queue_to_upload(&files_in_queue_to_upload, files_local_path, eval);
                    upload_file_controller.files_been_uploaded.with_mut(|i| *i = true);
                },
            })
        }
        if let Some(file) = storage_controller.read().show_file_modal.as_ref() {
            let file2 = file.clone();
            rsx!(get_file_modal {
                    on_dismiss: |_| {
                        storage_controller.with_mut(|i| i.show_file_modal = None);
                    },
                    on_download: move |_| {
                        let file_name = file2.clone().name();
                        functions::download_file(&file_name, ch);
                    },
                    file: file.clone()
                }
            )
        }
        div {
            id: "files-layout",
            aria_label: "files-layout",
            ondragover: move |_| {
                if upload_file_controller.are_files_hovering_app.with(|i| !(i)) {
                    upload_file_controller.are_files_hovering_app.with_mut(|i| *i = true);
                }
                },
            onclick: |_| {
                storage_controller.write().finish_renaming_item(false);
            },
            if show_slimbar {
                cx.render(rsx!(
                    SlimbarLayout {
                        active: crate::UplinkRoute::FilesLayout {}
                    },
                ))
            }
            ChatSidebar {
                active_route: crate::UplinkRoute::FilesLayout {},
            },
            div {
                class: "files-body disable-select",
                aria_label: "files-body",
                    Topbar {
                        with_back_button: state.read().ui.is_minimal_view() && state.read().ui.sidebar_hidden,
                        onback: move |_| {
                            let current = state.read().ui.sidebar_hidden;
                            state.write().mutate(Action::SidebarHidden(!current));
                        },
                        controls: cx.render(
                            rsx! (
                                Button {
                                    icon: Icon::ComputerDesktop,
                                    disabled: false,
                                    text: "Sync local folder".to_string(),
                                    appearance: Appearance::Secondary,
                                    aria_label: "desktop-sync-folder".into(),
                                    tooltip: cx.render(rsx!(
                                        Tooltip {
                                            arrow_position: ArrowPosition::Top,
                                            text: get_local_text("files.new-folder"),
                                        }
                                    )),
                                    onpress: move |_| {
                                        let storage_local_folder = STATIC_ARGS.uplink_path.join("storage_local_folder");
                                       let files_from_storage_local_folder = match list_files(storage_local_folder.to_string_lossy().to_string(), &mut vec![]) {
                                             Ok(vec) => vec,
                                             Err(e) => {
                                                println!("err: {:?}", e);
                                                Vec::new()
                                            },
                                       };
                                       let files_from_current_folder_in_constellation = state.read().storage.files.clone();
                                       let files_from_constellation_in_root_folder: Vec<String> = files_from_current_folder_in_constellation.iter().map(|file| {
                                        let file_path: String = file.path().to_string();
                                        let file_name: String = file.name();
                                        if file_path.contains(&file_name) {
                                            file_path
                                        } else {
                                            let correct_file_path = format!("{}{}", file_path, file_name);
                                            correct_file_path
                                        }
                                       }).collect();
                                       println!("files_from_storage_local_folder: {:?}\n\n\n", files_from_storage_local_folder.clone());
                                       
                                       println!("files_from_constellation_in_root_folder: {:?}\n\n\n", files_from_constellation_in_root_folder.clone());

                                       let unique_local_files: Vec<PathBuf> = files_from_storage_local_folder.clone()
                                        .into_iter()
                                        .filter(|local_file| {
                                            let local_file_str = local_file.to_str().unwrap_or("");
                                            !files_from_constellation_in_root_folder.contains(&local_file_str.to_string())
                                        })
                                        .map(|file| {
                                           let correct_local_file_path = format!("{}/{}", storage_local_folder.clone().to_string_lossy(), file.to_str().unwrap_or(""));
                                           PathBuf::from(correct_local_file_path)
                                        })
                                        .collect();

                                        println!("unique_local_files: {:?}", unique_local_files.clone());
                                        if unique_local_files.is_empty() {
                                         state.write().mutate(Action::AddToastNotification(
                                             ToastNotification::init(
                                                 "".into(),
                                                 "No files to sync".to_string(),
                                                 None,
                                                 2,
                                             ),
                                         ));
                                         return;
                                        } else {
                                         functions::add_files_in_queue_to_upload(upload_file_controller.files_in_queue_to_upload, unique_local_files, eval);
                                         upload_file_controller.files_been_uploaded.with_mut(|i| *i = true);
                                        }
 
                                    //      // Files that are in the constellation but not in the local folder
                                    //      let unique_constellation_files: Vec<File> = files_from_current_folder_in_constellation
                                    //      .into_iter()
                                    //      .filter(|constellation_file| {
                                    //          !files_from_storage_local_folder.clone()
                                    //              .iter()
                                    //              .any(|local_file| local_file.to_str().unwrap_or("") == &constellation_file.name())
                                    //      })
                                    //      .map(|file| {
                                    //          file
                                    //      })
                                    //      .collect();
                                    //      println!("unique_constellation_files: {:?}", unique_constellation_files.clone());
 
                                    //     for file in unique_constellation_files {
                                    //      let file_name = file.name();
                                    //      ch.send(ChanCmd::DownloadFile {
                                    //         file_name: file_name.to_string(),
                                    //         local_path_to_save_file: storage_local_folder.clone(),
                                    //     });
                                    //  }
 
                                    },
                                },
                                Button {
                                    icon: Icon::FolderPlus,
                                    disabled: *upload_file_controller.files_been_uploaded.read(),
                                    appearance: Appearance::Secondary,
                                    aria_label: "add-folder".into(),
                                    tooltip: cx.render(rsx!(
                                        Tooltip {
                                            arrow_position: ArrowPosition::Top,
                                            text: get_local_text("files.new-folder"),
                                        }
                                    )),
                                    onpress: move |_| {
                                        if !*upload_file_controller.files_been_uploaded.read() {
                                            storage_controller.write().finish_renaming_item(true);
                                        }
                                    },
                                },
                                Button {
                                    icon: Icon::Plus,
                                    appearance: Appearance::Secondary,
                                    aria_label: "upload-file".into(),
                                    tooltip: cx.render(rsx!(
                                        Tooltip {
                                            arrow_position: ArrowPosition::TopRight,
                                            text: get_local_text("files.upload"),
                                        }
                                    )),
                                    onpress: move |_| {
                                        storage_controller.with_mut(|i|  i.is_renaming_map = None);
                                        let files_local_path = match FileDialog::new().set_directory(".").pick_files() {
                                            Some(path) => path,
                                            None => return
                                        };
                                        functions::add_files_in_queue_to_upload(upload_file_controller.files_in_queue_to_upload, files_local_path, eval);
                                        upload_file_controller.files_been_uploaded.with_mut(|i| *i = true);
                                    },
                                }
                            )
                        ),
                        div {
                            class: "files-info",
                            aria_label: "files-info",
                            if storage_controller.read().storage_size.0.is_empty() {
                                rsx!(div {
                                    class: "skeletal-texts",
                                    div {
                                        class: "skeletal-text",
                                        div {
                                            class: "skeletal-text-content skeletal",
                                        }
                                    },
                                },
                                div {
                                    class: "skeletal-texts",
                                    div {
                                        class: "skeletal-text",
                                        div {
                                            class: "skeletal-text-content skeletal",
                                        }
                                    },
                                })
                            } else {
                                rsx!(
                                    p {
                                        class: "free-space",
                                        aria_label: "free-space-max-size",
                                        get_local_text("files.storage-max-size"),
                                        span {
                                            class: "count",
                                            format!("{}", storage_controller.read().storage_size.0),
                                        }
                                    },
                                    p {
                                        class: "free-space",
                                        aria_label: "free-space-current-size",
                                        get_local_text("files.storage-current-size"),
                                        span {
                                            class: "count",
                                            format!("{}", storage_controller.read().storage_size.1),
                                        }
                                    },
                                )
                            }
                        }
                    }
                    UploadProgressBar {
                        are_files_hovering_app: upload_file_controller.are_files_hovering_app,
                        files_been_uploaded: upload_file_controller.files_been_uploaded,
                        disable_cancel_upload_button: upload_file_controller.disable_cancel_upload_button,
                        on_update: move |files_to_upload: Vec<PathBuf>|  {
                            functions::add_files_in_queue_to_upload(upload_file_controller.files_in_queue_to_upload, files_to_upload, eval);
                        },
                        on_cancel: move |_| {
                            let _ = tx_cancel_file_upload.send(true);
                            let _ = tx_cancel_file_upload.send(false);
                        },
                    },
            SendFilesLayoutModal {
                send_files_from_storage: send_files_from_storage,
                send_files_start_location: SendFilesStartLocation::Storage,
                files_pre_selected_to_send: files_pre_selected_to_send.read().clone(),
                on_send: move |(files_location, convs_id): (Vec<Location>, Vec<Uuid>)| {
                    let warp_cmd_tx = WARP_CMD_CH.tx.clone();
                    let (tx, _) = oneshot::channel::<Result<(), warp::error::Error>>();
                    let msg = vec!["".to_owned()];
                    let attachments = files_location;
                    let ui_msg_id = None;
                    if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::SendMessageForSeveralChats {
                        convs_id,
                        msg,
                        attachments,
                        ui_msg_id,
                        rsp: tx,
                    })) {
                        log::error!("Failed to send warp command: {}", e);
                        return;
                    }
                    send_files_from_storage.set(false);
                }
            },
            FilesBreadcumbs {
                storage_controller: storage_controller,
                ch: ch,
                send_files_mode: false,
            },
            if storage_controller.read().files_list.is_empty()
                && storage_controller.read().directories_list.is_empty()
                && !storage_controller.read().add_new_folder {
                    rsx!(
                        div {
                            class: "no-files-div",
                            padding: "48px",
                            Label {
                                text: get_local_text("files.no-files-available"),
                            }
                        }
                        )
               } else {
                rsx!(FilesAndFolders {
                    storage_controller: storage_controller,
                    on_click_share_files: move |files_pre_selected: Vec<Location>| {
                        *files_pre_selected_to_send.write_silent() = files_pre_selected;
                        send_files_from_storage.set(true);
                    },
                    ch: ch,
                    send_files_mode: false,
                })
               }
                (state.read().ui.sidebar_hidden && state.read().ui.metadata.minimal_view).then(|| rsx!(
                    crate::AppNav {
                        active: crate::UplinkRoute::FilesLayout{},
                    }
                ))
            }
        }
    ))
}

fn list_files<P: AsRef<Path>>(path: P, files: &mut Vec<PathBuf>) -> io::Result<Vec<PathBuf>> {
    if path.as_ref().is_dir() {
        for entry in fs::read_dir(path)? {
            let entry = entry?;
            let path = entry.path();
            if path.is_dir() {
                list_files(&path, files)?;
            } else {
                if let Some(parent) = path.parent() {
                    if parent.ends_with("storage_local_folder") {
                        let new_path = Path::new("/").join(path.file_name().unwrap());
                        files.push(new_path);
                    } else {
                        files.push(path);
                    }
                } else {
                    files.push(path);
                }
            }
        }
    }
    Ok(files.clone())
}
