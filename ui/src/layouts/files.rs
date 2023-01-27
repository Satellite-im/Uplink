use dioxus::prelude::*;
use dioxus_router::*;
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

use crate::{
    components::chat::{sidebar::Sidebar as ChatSidebar, RouteInfo},
    state::{Action, State},
};

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

    let add_new_folder = use_state(cx, || false);

    let first_render = use_state(cx, || true);
    if *first_render.get() && state.read().ui.is_minimal_view() {
        state.write().mutate(Action::SidebarHidden(true));
        first_render.set(false);
    }

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
                    aria_label: "files-list",
                    add_new_folder.then(|| {
                        rsx!( Folder {
                            with_rename: true,
                            onrename: |val| {
                                println!("{:?}", val);
                                add_new_folder.set(false);
                             }
                        })
                    }),
                    span {
                        Folder {
                            text: "Fake Folder 1".into(),
                            aria_label: "fake-folder-1".into(),
                        },
                        File {
                            text: "fake_2.png".into(),
                            aria_label: "fake-file-1".into(),
                        },
                        Folder {
                            text: "New Fake".into(),
                            aria_label: "fake-folder-2".into(),
                        },
                        Folder {
                            loading: true,
                            text: "Fake Folder 1".into(),
                        },
                        File {
                            loading: true,
                            text: "Fake File".into(),
                        }
                    }
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
