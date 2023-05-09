#[allow(unused_imports)]
use std::path::Path;
use std::rc::Weak;
use std::{ffi::OsStr, path::PathBuf};

use common::icons::outline::Shape as Icon;
use common::icons::Icon as IconElement;
use common::language::get_local_text;
use common::state::ToastNotification;
use common::state::{storage::Storage, ui, Action, State};
use common::STATIC_ARGS;

use dioxus::{html::input_data::keyboard_types::Code, prelude::*};
use dioxus_desktop::{use_window, Config};
use dioxus_router::*;
use kit::{
    components::{
        context_menu::{ContextItem, ContextMenu},
        nav::Nav,
    },
    elements::{
        button::Button,
        file::File,
        folder::Folder,
        tooltip::{ArrowPosition, Tooltip},
        Appearance,
    },
    layout::topbar::Topbar,
};
use once_cell::sync::Lazy;
use rfd::FileDialog;
use uuid::Uuid;
use warp::constellation::directory::Directory;
use warp::constellation::item::Item;
use warp::sync::RwLock;
use wry::webview::FileDropEvent;

pub mod functions;
use crate::components::chat::{sidebar::Sidebar as ChatSidebar, RouteInfo};
use crate::get_window_builder;
use crate::layouts::file_preview::{FilePreview, FilePreviewProps};
use crate::layouts::storage::functions::{get_hard_disk_size, get_hard_disk_total_size};
use crate::utils::WindowDropHandler;
use crate::window_manager::WindowManagerCmd;

pub const FEEDBACK_TEXT_SCRIPT: &str = r#"
    const feedback_element = document.getElementById('overlay-text');
    feedback_element.textContent = '$TEXT';
"#;

const FILE_NAME_SCRIPT: &str = r#"
    const filename = document.getElementById('overlay-text0');
    filename.textContent = '$FILE_NAME';
"#;

pub const ANIMATION_DASH_SCRIPT: &str = r#"
    var dashElement = document.getElementById('dash-element')
    dashElement.style.animation = "border-dance 0.5s infinite linear"
"#;

const MAX_LEN_TO_FORMAT_NAME: usize = 15;

pub const ROOT_DIR_NAME: &str = "root";

pub static DRAG_EVENT: Lazy<RwLock<FileDropEvent>> =
    Lazy::new(|| RwLock::new(FileDropEvent::Cancelled));

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

#[derive(PartialEq, Props)]
pub struct Props {
    route_info: RouteInfo,
}

#[allow(non_snake_case)]
pub fn FilesLayout(cx: Scope<Props>) -> Element {
    let state = use_shared_state::<State>(cx)?;
    state.write_silent().ui.current_layout = ui::Layout::Storage;

    let storage_state: &UseState<Option<Storage>> = use_state(cx, || None);
    let storage_size: &UseRef<String> = use_ref(cx, || {
        get_local_text("files.no-data-available")
    });
    let current_dir = use_ref(cx, || state.read().storage.current_dir.clone());
    let directories_list = use_ref(cx, || state.read().storage.directories.clone());
    let files_list = use_ref(cx, || state.read().storage.files.clone());
    let dirs_opened_ref = use_ref(cx, || state.read().storage.directories_opened.clone());
    let is_renaming_map: &UseRef<Option<Uuid>> = use_ref(cx, || None);
    let add_new_folder = use_state(cx, || false);
    let drag_event: &UseRef<Option<FileDropEvent>> = use_ref(cx, || None);
    let first_render = use_state(cx, || true);
    let main_script = include_str!("./storage.js");
    let window = use_window(cx);

    let ch: &Coroutine<ChanCmd> = functions::storage_coroutine(
        cx,
        storage_state,
        storage_size,
        main_script.to_string(),
        window,
        drag_event,
    );

    functions::run_verifications_and_update_storage(
        first_render,
        state,
        storage_state,
        directories_list,
        files_list,
        current_dir,
        dirs_opened_ref,
        ch,
    );

    functions::allow_drag_event_for_non_macos_systems(cx, drag_event, window, main_script, ch);

    cx.render(rsx!(
        div {
            id: "overlay-element",
            class: "overlay-element",
            div {id: "dash-element", class: "dash-background active-animation"},
            p {id: "overlay-text0", class: "overlay-text"},
            p {id: "overlay-text", class: "overlay-text"}
        },
        div {
            id: "files-layout",
            aria_label: "files-layout",
            ondragover: move |_| {
                if drag_event.with(|i| i.clone()).is_none() {
                    cx.spawn({
                        to_owned![drag_event, window, ch, main_script];
                        async move {
                            functions::drag_and_drop_function(&window, &drag_event, main_script, &ch).await;
                        }
                    });
                }
                },
            onclick: |_| {
                add_new_folder.set(false);
                is_renaming_map.with_mut(|i| *i = None);
            },
            ChatSidebar {
                route_info: cx.props.route_info.clone()
            },
            div {
                class: "files-body disable-select",
                aria_label: "files-body",
                Topbar {
                    with_back_button: state.read().ui.is_minimal_view() || state.read().ui.sidebar_hidden,
                    onback: move |_| {
                        let current = state.read().ui.sidebar_hidden;
                        state.write().mutate(Action::SidebarHidden(!current));
                    },
                    controls: cx.render(
                        rsx! (
                            Button {
                                icon: Icon::FolderPlus,
                                appearance: Appearance::Secondary,
                                aria_label: "add-folder".into(),
                                tooltip: cx.render(rsx!(
                                    Tooltip {
                                        arrow_position: ArrowPosition::Top,
                                        text: get_local_text("files.new-folder"),
                                    }
                                )),
                                onpress: move |_| {
                                    is_renaming_map.with_mut(|i| *i = None);
                                    add_new_folder.set(!add_new_folder);
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
                                ))
                                onpress: move |_| {
                                    is_renaming_map.with_mut(|i| *i = None);
                                    let files_local_path = match FileDialog::new().set_directory(".").pick_files() {
                                        Some(path) => path,
                                        None => return
                                    };
                                    ch.send(ChanCmd::UploadFiles(files_local_path));
                                    cx.needs_update();
                                },
                            }
                        )
                    ),
                    div {
                        class: "files-info",
                        aria_label: "files-info",
                        p {
                            class: "free-space",
                            format!("{}", get_local_text("files.free-space")),
                            span {
                                class: "count",
                               format!("{}", get_hard_disk_size()),
                            }
                        },
                        p {
                            class: "total-space",
                            format!("{}", get_local_text("files.total-space")),
                            span {
                                class: "count",
                                format!("{}", get_hard_disk_total_size())
                            }
                        }
                    }
                    div {
                        class: "files-info",
                        aria_label: "files-info",
                        p {
                            class: "free-space",
                            format!("{}", get_local_text("files.storage-total-space")),
                            span {
                                class: "count",
                               format!("{}", storage_size.read()),
                            }
                        },
                    }
                }
                div {
                    class: "files-bar-track",
                    div {
                        class: "files-bar",
                    }
                },
                div {
                    class: "files-breadcrumbs",
                    aria_label: "files-breadcrumbs",
                    dirs_opened_ref.read().iter().enumerate().map(|(index, dir)| {
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
                                    "{folder_name_formatted}"
                                }
                            },)
                        }
                    })
                },
                span {
                    class: "file-parent",
                    div {
                        class: "files-list",
                        aria_label: "files-list",
                        add_new_folder.then(|| {
                            rsx!(
                            Folder {
                                with_rename: true,
                                onrename: |(val, key_code)| {
                                    let new_name: String = val;
                                    if directories_list.read().iter().any(|dir| dir.name() == new_name) {
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
                                        if STATIC_ARGS.use_mock {
                                            directories_list
                                                .with_mut(|i| i.insert(0, Directory::new(&new_name)));
                                            functions::update_items_with_mock_data(
                                                    storage_state,
                                                    current_dir,
                                                    dirs_opened_ref,
                                                    directories_list,
                                                    files_list,
                                                );
                                        } else if !new_name.is_empty() && !new_name.chars().all(char::is_whitespace) {
                                            ch.send(ChanCmd::CreateNewDirectory(new_name));
                                            ch.send(ChanCmd::GetItemsFromCurrentDirectory);
                                        }
                                    }
                                    add_new_folder.set(false);
                                 }
                            })
                        }),
                        directories_list.read().iter().map(|dir| {
                            let folder_name = dir.name();
                            let folder_name2 = dir.name();
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
                                                is_renaming_map.with_mut(|i| *i = Some(key));
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
                                    with_rename: *is_renaming_map.read() == Some(key),
                                    onrename: move |(val, key_code)| {
                                        if directories_list.read().iter().any(|dir| dir.name() == val) {
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
                                        is_renaming_map.with_mut(|i| *i = None);
                                        if key_code == Code::Enter {
                                            ch.send(ChanCmd::RenameItem{old_name: folder_name2.clone(), new_name: val});
                                        }
                                    }
                                    onpress: move |_| {
                                        is_renaming_map.with_mut(|i| *i = None);
                                        ch.send(ChanCmd::OpenDirectory(folder_name.clone()));
                                    }
                            }})
                        }),
                       files_list.read().iter().map(|file| {
                            let file_name = file.name();
                            let file_name2 = file.name();
                            let file2 = file.clone();
                            let file3 = file.clone();
                            let key = file.id();
                            let file_id = file.id();
                            rsx!(ContextMenu {
                                        key: "{key}-menu",
                                        id: file.id().to_string(),
                                        items: cx.render(rsx!(
                                            ContextItem {
                                                icon: Icon::Pencil,
                                                aria_label: "files-rename".into(),
                                                text: get_local_text("files.rename"),
                                                onpress: move |_| {
                                                    is_renaming_map.with_mut(|i| *i = Some(key));
                                                }
                                            },
                                            ContextItem {
                                                icon: Icon::ArrowDownCircle,
                                                aria_label: "files-download".into(),
                                                text: get_local_text("files.download"),
                                                onpress: move |_| {
                                                    let file_extension = std::path::Path::new(&file_name2)
                                                        .extension()
                                                        .and_then(OsStr::to_str)
                                                        .map(|s| s.to_string())
                                                        .unwrap_or_default();
                                                    let file_stem = PathBuf::from(&file_name2)
                                                        .file_stem()
                                                        .and_then(OsStr::to_str)
                                                        .map(str::to_string)
                                                        .unwrap_or_default();
                                                    let file_path_buf = match FileDialog::new().set_directory(".").set_file_name(&file_stem).add_filter("", &[&file_extension]).save_file() {
                                                        Some(path) => path,
                                                        None => return,
                                                    };
                                                    ch.send(ChanCmd::DownloadFile { file_name: file_name2.clone(), local_path_to_save_file: file_path_buf } );
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
                                            },
                                        )),
                                        File {
                                            key: "{key}-file",
                                            thumbnail: file.thumbnail(),
                                            text: file.name(),
                                            aria_label: file.name(),
                                            with_rename: *is_renaming_map.read() == Some(key),
                                            onpress: move |_| {
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

                                                let drop_handler = WindowDropHandler::new(WindowManagerCmd::ForgetFilePreview(key));
                                                let file_preview = VirtualDom::new_with_props(FilePreview, FilePreviewProps {
                                                    file: file3.clone(),
                                                    _drop_handler: drop_handler
                                                });
                                                let config = Config::default().with_window(get_window_builder(false, false));

                                                let window = window.new_window(file_preview, config);
                                                if let Some(wv) = Weak::upgrade(&window) {
                                                    let id = wv.window().id();
                                                    state.write().mutate(Action::AddFilePreview(key, id));
                                                }
                                            },
                                            onrename: move |(val, key_code)| {
                                                let new_name: String = val;
                                                if  files_list.read().iter().any(|file| file.name() == new_name) {
                                                    state
                                                    .write()
                                                    .mutate(common::state::Action::AddToastNotification(
                                                        ToastNotification::init(
                                                            "".into(),
                                                            get_local_text("files.file-alrady-with-name"),
                                                            None,
                                                            3,
                                                        ),
                                                    ));
                                                    return;
                                                }
                                                is_renaming_map.with_mut(|i| *i = None);
                                                if key_code == Code::Enter && !new_name.is_empty() && !new_name.chars().all(char::is_whitespace) {
                                                    ch.send(ChanCmd::RenameItem{old_name: file_name.clone(), new_name});
                                                }
                                            }
                                        }
                                    }
                              )
                        }),
                    },
                }

                (state.read().ui.sidebar_hidden && state.read().ui.metadata.minimal_view).then(|| rsx!(
                    Nav {
                        routes: cx.props.route_info.routes.clone(),
                        active: cx.props.route_info.active.clone(),
                        onnavigate: move |r| {
                            use_router(cx).replace_route(r, None, None);
                        }
                    }
                ))
            }
        }
    ))
}
