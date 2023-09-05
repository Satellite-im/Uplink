#[allow(unused_imports)]
use std::path::Path;
use std::rc::Rc;
use std::time::Duration;
use std::{ffi::OsStr, path::PathBuf};

use common::icons::outline::Shape as Icon;
use common::icons::Icon as IconElement;
use common::language::get_local_text;
use common::state::ToastNotification;
use common::state::{ui, Action, State};
use common::upload_file_channel::{
    UploadFileAction, CANCEL_FILE_UPLOADLISTENER, UPLOAD_FILE_LISTENER,
};
use common::warp_runner::thumbnail_to_base64;
use common::ROOT_DIR_NAME;
use dioxus::{html::input_data::keyboard_types::Code, prelude::*};
use dioxus_desktop::use_window;
use dioxus_router::prelude::use_navigator;
use kit::{
    components::context_menu::{ContextItem, ContextMenu},
    elements::{
        button::Button,
        file::File,
        folder::Folder,
        tooltip::{ArrowPosition, Tooltip},
        Appearance,
    },
    layout::topbar::Topbar,
};
use rfd::FileDialog;
use warp::constellation::directory::Directory;
use warp::constellation::item::Item;
use warp::raygun::Location;

pub mod controller;
pub mod file_modal;
pub mod functions;
pub mod send_files_components;

use crate::components::chat::sidebar::Sidebar as ChatSidebar;
use crate::components::files::upload_progress_bar::UploadProgressBar;
use crate::components::paste_files_with_shortcut;
use crate::layouts::slimbar::SlimbarLayout;
use crate::layouts::storage::file_modal::get_file_modal;
use crate::layouts::storage::send_files_components::{
    add_remove_file_to_send, file_checkbox, send_files_from_chat_topbar,
};

use self::controller::{StorageController, UploadFileController};

const MAX_LEN_TO_FORMAT_NAME: usize = 64;

static ALLOW_FOLDER_NAVIGATION: &str = r#"
    var folders_element = document.getElementById('files-list');
    folders_element.style.pointerEvents = '$POINTER_EVENT';
    folders_element.style.opacity = '$OPACITY';
    var folders_breadcumbs_element = document.getElementById('files-breadcrumbs');
    folders_breadcumbs_element.style.pointerEvents = '$POINTER_EVENT';
    folders_breadcumbs_element.style.opacity = '$OPACITY';
"#;

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

#[derive(Props)]
pub struct Props<'a> {
    storage_files_to_chat_mode_is_active: Option<UseState<bool>>,
    on_files_selected_to_send: Option<EventHandler<'a, Vec<Location>>>,
}

#[allow(non_snake_case)]
pub fn FilesLayout<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let state = use_shared_state::<State>(cx)?;
    state.write_silent().ui.current_layout = ui::Layout::Storage;
    let on_files_selected_to_send = cx.props.on_files_selected_to_send.as_ref();
    let storage_files_to_chat_mode_is_active =
        match cx.props.storage_files_to_chat_mode_is_active.as_ref() {
            Some(d) => d,
            None => use_state(cx, || false),
        };
    let storage_controller = StorageController::new(cx, state);
    let upload_file_controller = UploadFileController::new(cx, state.clone());
    let window = use_window(cx);
    let files_in_queue_to_upload = upload_file_controller.files_in_queue_to_upload.clone();
    let files_been_uploaded = upload_file_controller.files_been_uploaded.clone();

    let _router = use_navigator(cx);
    let eval: &UseEvalFn = use_eval(cx);

    use_allow_block_folder_nav(cx, &files_in_queue_to_upload);

    let ch: &Coroutine<ChanCmd> = functions::init_coroutine(cx, storage_controller);

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
        upload_file_controller.files_in_queue_to_upload,
    );

    functions::get_items_from_current_directory(cx, ch);

    if !*storage_files_to_chat_mode_is_active.get() {
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
    }

    let tx_cancel_file_upload = CANCEL_FILE_UPLOADLISTENER.tx.clone();

    cx.render(rsx!(
        if state.read().ui.metadata.focused && !*storage_files_to_chat_mode_is_active.get() {
            rsx!(paste_files_with_shortcut::PasteFilesShortcut {
                on_paste: move |files_local_path| {
                    add_files_in_queue_to_upload(&files_in_queue_to_upload, files_local_path, eval);
                    upload_file_controller.files_been_uploaded.with_mut(|i| *i = true);
                },
            })
        }
        if let Some(file) = storage_controller.read().show_file_modal.as_ref() {
            let file2 = file.clone();
            rsx!(
                get_file_modal {
                    on_dismiss: |_| {
                        storage_controller.with_mut(|i| i.show_file_modal = None);
                    },
                    on_download: move |_| {
                        let file_name = file2.clone().name();
                        download_file(&file_name, ch);
                    },
                    file: file.clone()
                }
            )
        }
        div {
            id: "files-layout",
            aria_label: "files-layout",
            ondragover: move |_| {
                if !*storage_files_to_chat_mode_is_active.get() && upload_file_controller.are_files_hovering_app.with(|i| !(i)) {
                    upload_file_controller.are_files_hovering_app.with_mut(|i| *i = true);
                }
                },
            onclick: |_| {
                storage_controller.write().finish_renaming_item(false);
            },
            if !*storage_files_to_chat_mode_is_active.get() {
                rsx!(
                    SlimbarLayout {
                        active: crate::UplinkRoute::FilesLayout {}
                    },
                    ChatSidebar {
                        active_route: crate::UplinkRoute::FilesLayout {},
                    },
                )
            }
            div {
                class: "files-body disable-select",
                aria_label: "files-body",
                if !*storage_files_to_chat_mode_is_active.get() {
                    rsx!(Topbar {
                        with_back_button: state.read().ui.is_minimal_view() && state.read().ui.sidebar_hidden,
                        onback: move |_| {
                            let current = state.read().ui.sidebar_hidden;
                            state.write().mutate(Action::SidebarHidden(!current));
                        },
                        controls: cx.render(
                            rsx! (
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
                                            arrow_position: ArrowPosition::Top,
                                            text: get_local_text("files.upload"),
                                        }
                                    )),
                                    onpress: move |_| {
                                        storage_controller.with_mut(|i|  i.is_renaming_map = None);
                                        let files_local_path = match FileDialog::new().set_directory(".").pick_files() {
                                            Some(path) => path,
                                            None => return
                                        };
                                        add_files_in_queue_to_upload(upload_file_controller.files_in_queue_to_upload, files_local_path, eval);
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
                                        format!("{}", get_local_text("files.storage-max-size")),
                                        span {
                                            class: "count",
                                           format!("{}", storage_controller.read().storage_size.0),
                                        }
                                    },
                                    p {
                                        class: "free-space",
                                        aria_label: "free-space-current-size",
                                        format!("{}", get_local_text("files.storage-current-size")),
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
                            add_files_in_queue_to_upload(upload_file_controller.files_in_queue_to_upload, files_to_upload, eval);
                        },
                        on_cancel: move |_| {
                            let _ = tx_cancel_file_upload.send(true);
                            let _ = tx_cancel_file_upload.send(false);
                        },
                    }
                 )
                }
                send_files_from_chat_topbar {
                    storage_controller: storage_controller.clone(),
                    select_files_to_send_mode: storage_files_to_chat_mode_is_active.clone(),
                    on_press_send_files_button: move |files_location_path| {
                        if let Some(f) = on_files_selected_to_send {
                            f.call(files_location_path);
                        }
                    }
                }
                div {
                    id: "files-breadcrumbs",
                    class: "files-breadcrumbs",
                    aria_label: "files-breadcrumbs",
                    storage_controller.read().dirs_opened_ref.iter().enumerate().map(|(index, dir)| {
                        let directory = dir.clone();
                        let dir_name = dir.name();
                        if dir_name == ROOT_DIR_NAME && index == 0 {
                            let home_text = get_local_text("uplink.home");
                            rsx!(div {
                                class: "crumb",
                                aria_label: "crumb",
                                onclick: move |_| {
                                    ch.send(ChanCmd::BackToPreviousDirectory(directory.clone()));
                                },
                                IconElement {
                                    icon: Icon::Home,
                                },
                                p {
                                    aria_label: "home-dir",
                                    "{home_text}",
                                }
                            })
                        } else {
                            let folder_name_formatted = functions::format_item_name(dir_name);
                            rsx!(div {
                                class: "crumb",
                                onclick: move |_| {
                                    ch.send(ChanCmd::BackToPreviousDirectory(directory.clone()));
                                },
                                aria_label: "crumb",
                                p {
                                    aria_label: "{folder_name_formatted}",
                                    "{folder_name_formatted}"
                                }
                            },)
                        }
                    })
                },
                span {
                    class: "file-parent",
                    div {
                        id: "files-list",
                        class: "files-list",
                        aria_label: "files-list",
                        storage_controller.read().add_new_folder.then(|| {
                            rsx!(
                            Folder {
                                with_rename: true,
                                onrename: |(val, key_code)| {
                                    let new_name: String = val;
                                    if storage_controller.read().directories_list.iter().any(|dir| dir.name() == new_name) {
                                        state
                                        .write()
                                        .mutate(common::state::Action::AddToastNotification(
                                            ToastNotification::init(
                                                "".into(),
                                                get_local_text("files.directory-already-with-name"),
                                                None,
                                                3,
                                            ),
                                        ));
                                        return;
                                    }
                                    if key_code == Code::Enter {
                                        ch.send(ChanCmd::CreateNewDirectory(new_name));
                                        ch.send(ChanCmd::GetItemsFromCurrentDirectory);
                                    }
                                    storage_controller.with_mut(|i| i.add_new_folder = false);
                                 }
                            })
                        }),
                        storage_controller.read().directories_list.iter().map(|dir| {
                            let folder_name = dir.name();
                            let folder_name2 = dir.name();
                            let folder_name3 = dir.name();
                            let key = dir.id();
                            let dir2 = dir.clone();
                            rsx!(
                                ContextMenu {
                                    key: "{key}-menu",
                                    id: dir.id().to_string(),
                                    items: cx.render(rsx!(
                                        ContextItem {
                                            icon: Icon::Pencil,
                                            aria_label: "folder-rename".into(),
                                            text: get_local_text("files.rename"),
                                            onpress: move |_| {
                                                storage_controller.with_mut(|i| i.is_renaming_map = Some(key));
                                            }
                                        },
                                        hr {},
                                        ContextItem {
                                            icon: Icon::Trash,
                                            danger: true,
                                            aria_label: "folder-delete".into(),
                                            text: get_local_text("uplink.delete"),
                                            onpress: move |_| {
                                                let item = Item::from(dir2.clone());
                                                ch.send(ChanCmd::DeleteItems(item));
                                            }
                                        },
                                    )),
                                    Folder {
                                        key: "{key}-folder",
                                        text: dir.name(),
                                        aria_label: dir.name(),
                                        with_rename:storage_controller.with(|i| i.is_renaming_map == Some(key)),
                                        onrename: move |(val, key_code)| {
                                            if val == folder_name3 {
                                                storage_controller.with(|i| i.is_renaming_map.is_none());
                                                storage_controller.write().finish_renaming_item(false);
                                                return;
                                            };
                                            if storage_controller.read().directories_list.iter().any(|dir| dir.name() == val) {
                                                state
                                                .write()
                                                .mutate(common::state::Action::AddToastNotification(
                                                    ToastNotification::init(
                                                        "".into(),
                                                        get_local_text("files.directory-already-with-name"),
                                                        None,
                                                        3,
                                                    ),
                                                ));
                                                return;
                                            }
                                            storage_controller.with_mut(|i| i.is_renaming_map = None);
                                            storage_controller.write().finish_renaming_item(false);
                                            if key_code == Code::Enter {
                                                ch.send(ChanCmd::RenameItem{old_name: folder_name2.clone(), new_name: val});
                                            }
                                        },
                                        onpress: move |_| {
                                            storage_controller.with_mut(|i| i.is_renaming_map = None);
                                            ch.send(ChanCmd::OpenDirectory(folder_name.clone()));
                                        }
                                    }
                                }
                            )
                        }),
                        storage_controller.read().files_list.iter().map(|file| {
                            let file_name = file.name();
                            let file_name2 = file.name();
                            let file_name3 = file.name();
                            let file_path = format!("{}/{}", storage_controller.read().current_dir_path_as_string, file_name3);
                            let file_path2 = format!("{}/{}", storage_controller.read().current_dir_path_as_string, file_name3);
                            let file2 = file.clone();
                            let file3 = file.clone();
                            let key = file.id();
                            let file_id = file.id();
                            rsx! {
                                ContextMenu {
                                    key: "{key}-menu",
                                    id: file.id().to_string(),
                                    items: cx.render(rsx!(
                                        ContextItem {
                                            icon: Icon::Pencil,
                                            aria_label: "files-rename".into(),
                                            text: get_local_text("files.rename"),
                                            onpress: move |_| {
                                                storage_controller.with_mut(|i| i.is_renaming_map = Some(key));
                                            }
                                        },
                                        if !*storage_files_to_chat_mode_is_active.get() {
                                            rsx!( ContextItem {
                                                icon: Icon::ArrowDownCircle,
                                                aria_label: "files-download".into(),
                                                text: get_local_text("files.download"),
                                                onpress: move |_| {
                                                    download_file(&file_name2, ch);
                                                },
                                            },
                                            hr {},
                                            ContextItem {
                                                icon: Icon::Trash,
                                                danger: true,
                                                aria_label: "files-delete".into(),
                                                text: get_local_text("uplink.delete"),
                                                onpress: move |_| {
                                                    let item = Item::from(file2.clone());
                                                    ch.send(ChanCmd::DeleteItems(item));
                                                }
                                            },)
                                        }
                                    )),
                                    div {
                                        class: "file-wrap",
                                        file_checkbox {
                                            file_path: file_path.clone(),
                                            storage_controller: storage_controller.clone(),
                                            select_files_to_send_mode: storage_files_to_chat_mode_is_active.clone(),
                                        },
                                        File {
                                            key: "{key}-file",
                                            thumbnail: thumbnail_to_base64(file),
                                            text: file.name(),
                                            aria_label: file.name(),
                                            with_rename: storage_controller.with(|i| i.is_renaming_map == Some(key)),
                                            onpress: move |_| {
                                                if *storage_files_to_chat_mode_is_active.get() {
                                                    add_remove_file_to_send(storage_controller.clone(), file_path2.clone());
                                                    return;
                                                }
                                                let key = file_id;
                                                if state.read().ui.file_previews.contains_key(&key) {
                                                    state
                                                    .write()
                                                    .mutate(common::state::Action::AddToastNotification(
                                                        ToastNotification::init(
                                                            "".into(),
                                                            get_local_text("files.file-already-opened"),
                                                            None,
                                                            2,
                                                        ),
                                                    ));
                                                    return;
                                                }
                                                if file3.thumbnail().is_empty() {
                                                    state
                                                    .write()
                                                    .mutate(common::state::Action::AddToastNotification(
                                                        ToastNotification::init(
                                                            "".into(),
                                                            get_local_text("files.no-thumbnail-preview"),
                                                            None,
                                                            3,
                                                        ),
                                                    ));
                                                    return;
                                                }
                                                let file4 = file3.clone();
                                                storage_controller.with_mut(|i| i.show_file_modal = Some(file4));
                                            },
                                            onrename: move |(val, key_code)| {
                                                let new_name: String = val;
                                                if new_name == file_name3 {
                                                    storage_controller.with(|i| i.is_renaming_map.is_none());
                                                    storage_controller.write().finish_renaming_item(false);
                                                    return;
                                                };
                                                if  storage_controller.read().files_list.iter().any(|file| file.name() == new_name) {
                                                    state
                                                    .write()
                                                    .mutate(common::state::Action::AddToastNotification(
                                                        ToastNotification::init(
                                                            "".into(),
                                                            get_local_text("files.file-already-with-name"),
                                                            None,
                                                            3,
                                                        ),
                                                    ));
                                                    return;
                                                }
                                                storage_controller.with(|i| i.is_renaming_map.is_none());
                                                storage_controller.write().finish_renaming_item(false);
                                                if key_code == Code::Enter && !new_name.is_empty() && !new_name.chars().all(char::is_whitespace) {
                                                    ch.send(ChanCmd::RenameItem{old_name: file_name.clone(), new_name});
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }),
                    },
                },
                (state.read().ui.sidebar_hidden && state.read().ui.metadata.minimal_view).then(|| rsx!(
                    crate::AppNav {
                        active: crate::UplinkRoute::FilesLayout{},
                    }
                ))
            }
        }
    ))
}

type UseEvalFn = Rc<dyn Fn(&str) -> Result<UseEval, EvalError>>;

fn download_file(file_name: &str, ch: &Coroutine<ChanCmd>) {
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

fn add_files_in_queue_to_upload(
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

fn use_allow_block_folder_nav(cx: &ScopeState, files_in_queue_to_upload: &UseRef<Vec<PathBuf>>) {
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

fn allow_folder_navigation(eval: &UseEvalFn, allow_navigation: bool) {
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
