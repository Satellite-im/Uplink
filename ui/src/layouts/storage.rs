use std::{path::PathBuf, time::Duration};

use dioxus::{html::input_data::keyboard_types::Code, prelude::*};
use dioxus_router::*;
use futures::{channel::oneshot, StreamExt};
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
    icons::{Icon, IconElement},
    layout::topbar::Topbar,
};
use rfd::FileDialog;
use shared::language::get_local_text;
use tokio::time::sleep;
use uuid::Uuid;
use warp::{
    constellation::{directory::Directory, file::File},
    logging::tracing::log,
};

use crate::{
    components::chat::{sidebar::Sidebar as ChatSidebar, RouteInfo},
    state::{storage::Storage, Action, State},
    warp_runner::{ConstellationCmd, WarpCmd},
    STATIC_ARGS, WARP_CMD_CH,
};

pub const ROOT_DIR_NAME: &str = "root";

enum ChanCmd {
    GetItemsFromCurrentDirectory,
    CreateNewDirectory(String),
    OpenDirectory(String),
    BackToPreviousDirectory(Directory),
    UploadFiles(Vec<PathBuf>),
    RenameItem { old_name: String, new_name: String },
}

#[derive(PartialEq, Props)]
pub struct Props {
    route_info: RouteInfo,
}

#[allow(non_snake_case)]
pub fn FilesLayout(cx: Scope<Props>) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let free_space_text = get_local_text("files.free-space");
    let total_space_text = get_local_text("files.total-space");
    let storage_state: &UseState<Option<Storage>> = use_state(cx, || None);
    let current_dir = use_ref(cx, || state.read().storage.current_dir.clone());
    let directories_list = use_ref(cx, || state.read().storage.directories.clone());
    let files_list = use_ref(cx, || state.read().storage.files.clone());
    let dirs_opened_ref = use_ref(cx, || state.read().storage.directories_opened.clone());

    let add_new_folder = use_state(cx, || false);

    if let Some(storage) = storage_state.get().clone() {
        if !STATIC_ARGS.use_mock {
            *directories_list.write_silent() = storage.directories.clone();
            *files_list.write_silent() = storage.files.clone();
            *current_dir.write_silent() = storage.current_dir.clone();
            *dirs_opened_ref.write_silent() = storage.directories_opened.clone();
        };
        state.write().storage = storage;
        storage_state.set(None);
    }

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
                        let (tx, rx) = oneshot::channel::<Result<Storage, warp::error::Error>>();

                        if let Err(e) = warp_cmd_tx.send(WarpCmd::Constellation(
                            ConstellationCmd::UploadFiles {
                                files_path,
                                rsp: tx,
                            },
                        )) {
                            log::error!("failed to upload files {}", e);
                            continue;
                        }

                        let rsp = rx.await.expect("command canceled");
                        match rsp {
                            Ok(storage) => {
                                storage_state.set(Some(storage));
                            }
                            Err(e) => {
                                log::error!("failed to add new files into uplink storage: {}", e);
                                continue;
                            }
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
                }
            }
        }
    });

    let is_renaming_map: &UseRef<Option<Uuid>> = use_ref(cx, || None);

    let first_render = use_state(cx, || true);
    if *first_render.get() && state.read().ui.is_minimal_view() {
        state.write().mutate(Action::SidebarHidden(true));
        first_render.set(false);
    }
    if !STATIC_ARGS.use_mock {
        use_future(cx, (), |_| {
            to_owned![ch];
            async move {
                sleep(Duration::from_millis(100)).await;
                ch.send(ChanCmd::GetItemsFromCurrentDirectory);
            }
        });
    };

    cx.render(rsx!(
        div {
            id: "files-layout",
            aria_label: "files-layout",
            onclick: |_| is_renaming_map.with_mut(|i| *i = None),
            ChatSidebar {
                route_info: cx.props.route_info.clone()
            },
            div {
                class: "files-body",
                aria_label: "files-body",
                Topbar {
                    with_back_button: state.read().ui.is_minimal_view() || state.read().ui.sidebar_hidden,
                    with_currently_back: state.read().ui.sidebar_hidden,
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
                            "{free_space_text}",
                            span {
                                class: "count",
                                "0MB"
                            }
                        },
                        p {
                            class: "total-space",
                            "{total_space_text}",
                            span {
                                class: "count",
                                "10MB"
                            }
                        }
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
                            rsx!(div {
                                class: "crumb",
                                onclick: move |_| {
                                    ch.send(ChanCmd::BackToPreviousDirectory(directory.clone()));
                                },
                                aria_label: "crumb",
                                p {
                                    "{dir_name}"
                                }
                            },)
                        }
                    })
                },
                div {
                    class: "files-list",
                    flex: if state.read().ui.sidebar_hidden {
                        "1"
                    } else {
                        "0"
                    },
                    aria_label: "files-list",
                    add_new_folder.then(|| {
                        rsx!(
                        Folder {
                            with_rename: true,
                            onrename: |(val, key_code)| {
                                let new_name: String = val;
                                if key_code == Code::Enter {
                                    if STATIC_ARGS.use_mock {
                                        directories_list
                                            .with_mut(|i| i.insert(0, Directory::new(&new_name)));
                                            update_items_with_mock_data(
                                                storage_state,
                                                current_dir,
                                                dirs_opened_ref,
                                                directories_list,
                                                files_list,
                                            );
                                    } else {
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
                        rsx!(
                            ContextMenu {
                                key: "{key}-menu",
                                id: dir.id().to_string(),
                                items: cx.render(rsx!(
                                    ContextItem {
                                        icon: Icon::Pencil,
                                        text: get_local_text("files.rename"),
                                        onpress: move |_| {
                                            is_renaming_map.with_mut(|i| *i = Some(key));
                                        }
                                    })),
                            Folder {
                                key: "{key}-folder",
                                text: dir.name(),
                                aria_label: dir.name(),
                                with_rename: *is_renaming_map.read() == Some(key),
                                onrename: move |(val, key_code)| {
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
                        let key = file.id();
                        rsx!(ContextMenu {
                                    key: "{key}-menu",
                                    id: file.id().to_string(),
                                    items: cx.render(rsx!(
                                        ContextItem {
                                            icon: Icon::Pencil,
                                            text: get_local_text("files.rename"),
                                            onpress: move |_| {
                                                is_renaming_map.with_mut(|i| *i = Some(key));
                                            }
                                        })),
                                            File {
                                                key: "{key}-file",
                                                thumbnail: file.thumbnail(),
                                                text: file.name(),
                                                aria_label: file.name(),
                                                with_rename: *is_renaming_map.read() == Some(key),
                                                onrename: move |(val, key_code)| {
                                                    is_renaming_map.with_mut(|i| *i = None);
                                                    if key_code == Code::Enter {
                                                        ch.send(ChanCmd::RenameItem{old_name: file_name.clone(), new_name: val});
                                                    }
                                                }
                                    }
                          }
                          )
                    }),
                },
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

fn update_items_with_mock_data(
    storage_state: &UseState<Option<Storage>>,
    current_dir: &UseRef<Directory>,
    directories_opened: &UseRef<Vec<Directory>>,
    directories_list: &UseRef<Vec<Directory>>,
    files_list: &UseRef<Vec<File>>,
) {
    let storage_mock = Storage {
        initialized: true,
        directories_opened: directories_opened.read().clone(),
        current_dir: current_dir.read().clone(),
        directories: directories_list.read().clone(),
        files: files_list.read().clone(),
    };
    storage_state.set(Some(storage_mock));
}
