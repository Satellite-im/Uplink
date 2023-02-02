use std::time::Duration;

use dioxus::prelude::*;
use dioxus_router::*;
use futures::{channel::oneshot, StreamExt};
use kit::{
    components::nav::Nav,
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
use shared::language::get_local_text;
use tokio::time::sleep;
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

enum ChanCmd {
    GetItemsFromCurrentDirectory,
    AddNewFolder(String),
}

#[derive(PartialEq, Props)]
pub struct Props {
    route_info: RouteInfo,
}

#[allow(non_snake_case)]
pub fn FilesLayout(cx: Scope<Props>) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let home_text = get_local_text("uplink.home");
    let free_space_text = get_local_text("files.free-space");
    let total_space_text = get_local_text("files.total-space");
    let storage_state: &UseState<Option<Storage>> = use_state(cx, || None);
    let directories_list = use_ref(cx, || state.read().storage.directories.clone());
    let files_list = use_ref(cx, || state.read().storage.files.clone());

    let add_new_folder = use_state(cx, || false);

    if let Some(storage) = storage_state.get().clone() {
        if STATIC_ARGS.use_mock == false {
            *directories_list.write_silent() = storage.directories.clone();
            *files_list.write_silent() = storage.files.clone();
        };
        state.write().storage = storage.clone();
        storage_state.set(None);
    }

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<ChanCmd>| {
        to_owned![storage_state];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(cmd) = rx.next().await {
                match cmd {
                    ChanCmd::AddNewFolder(folder_name) => {
                    
                            let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();
                            let folder_name2 = folder_name.clone();
                            warp_cmd_tx
                                .send(WarpCmd::Constellation(ConstellationCmd::CreateNewFolder {
                                    folder_name,
                                    rsp: tx,
                                }))
                                .expect("failed to send cmd");

                            let rsp = rx.await.expect("command canceled");

                            match rsp {
                                Ok(_) => {
                                    log::info!("New folder added: {}", folder_name2);
                                }
                                Err(e) => {
                                    log::error!("failed to add new folder conversation: {}", e);
                                    continue;
                                }
                            }
                    }
                    ChanCmd::GetItemsFromCurrentDirectory => {
                                             let (tx, rx) =
                                oneshot::channel::<Result<Storage, warp::error::Error>>();
                            warp_cmd_tx
                                .send(WarpCmd::Constellation(
                                    ConstellationCmd::GetItemsFromCurrentDirectory { rsp: tx },
                                ))
                                .expect("failed to send cmd");

                            let rsp = rx.await.expect("command canceled");
                            match rsp {
                                Ok(storage) => {
                                    storage_state.set(Some(storage));
                                }
                                Err(e) => {
                                    log::error!("failed to add new folder conversation: {}", e);
                                    continue;
                                }
                            }
                        
                    }
                }
            }
        }
    });

    let first_render = use_state(cx, || true);
    if *first_render.get() && state.read().ui.is_minimal_view() {
        state.write().mutate(Action::SidebarHidden(true));
        first_render.set(false);
    }

    use_future(cx, (), |_| {
        to_owned![ch];
        async move {
            sleep(Duration::from_millis(100)).await;
            ch.send(ChanCmd::GetItemsFromCurrentDirectory);
        }
    });

    cx.render(rsx!(
        div {
            id: "files-layout",
            aria_label: "files-layout",
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
                    div {
                        class: "crumb",
                        aria_label: "crumb",
                        IconElement {
                            icon: Icon::Home,
                        },
                        p {
                            "{home_text}",
                        }
                    },
                    div {
                        class: "crumb",
                        aria_label: "crumb",
                        p {
                            "Folder 1"
                        }
                    },
                    div {
                        class: "crumb",
                        aria_label: "crumb",
                        p {
                            "Folder 3"
                        }
                    },
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
                            onrename: |val| {
                                let new_name: String = val;
                                if STATIC_ARGS.use_mock {
                                    directories_list
                                        .with_mut(|i| i.insert(0, Directory::new(&new_name)));
                                        update_items_with_mock_data(
                                            storage_state.clone(),
                                            directories_list.clone(),
                                            files_list.clone(),
                                        );
                                } else {
                                    ch.send(ChanCmd::AddNewFolder(new_name));
                                    ch.send(ChanCmd::GetItemsFromCurrentDirectory);
                                }
                               
                                add_new_folder.set(false);
                             }
                        })
                    }),
                    directories_list.read().iter().map(|dir| {
                        rsx!(Folder {
                            text: dir.name(),
                            aria_label: dir.name(),
                        })
                    }),
                    files_list.read().iter().map(|file| {
                        rsx!(File {
                            text: file.name(),
                            aria_label: file.name(),
                        })
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
    storage_state: UseState<Option<Storage>>,
    directories_list: UseRef<Vec<Directory>>,
    files_list: UseRef<Vec<File>>,
) {
    let storage_mock = Storage {
        initialized: true,
        directories: directories_list.read().clone(),
        files: files_list.read().clone(),
    };
    storage_state.set(Some(storage_mock.clone()));
}
