use dioxus::prelude::*;
use ui_kit::{
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

use crate::components::chat::{sidebar::Sidebar as ChatSidebar, RouteInfo};

#[derive(PartialEq, Props)]
pub struct Props {
    route_info: RouteInfo,
}

#[allow(non_snake_case)]
pub fn FilesLayout(cx: Scope<Props>) -> Element {
    cx.render(rsx!(
        div {
            id: "files-layout",
            ChatSidebar {
                route_info: cx.props.route_info.clone()
            },
            div {
                class: "files-body",
                Topbar {
                    with_back_button: false,
                    controls: cx.render(
                        rsx! (
                            Button {
                                icon: Icon::FolderPlus,
                                appearance: Appearance::Secondary,
                                tooltip: cx.render(rsx!(
                                    Tooltip {
                                        arrow_position: ArrowPosition::Top,
                                        text: String::from("New Folder")
                                    }
                                )),
                                onpress: move |_| {
                                    // ...
                                }
                            },
                            Button {
                                icon: Icon::Plus,
                                appearance: Appearance::Secondary,
                                tooltip: cx.render(rsx!(
                                    Tooltip {
                                        arrow_position: ArrowPosition::Top,
                                        text: String::from("Upload")
                                    }
                                ))
                            }
                        )
                    ),
                    div {
                        class: "files-info",
                        p {
                            class: "free-space",
                            "Free space:",
                            span {
                                class: "count",
                                "0MB"
                            }
                        },
                        p {
                            class: "total-space",
                            "Total space:",
                            span {
                                class: "count",
                                "10MB"
                            }
                        }
                    }
                },
                div {
                    class: "files-bar-track",
                    div {
                        class: "files-bar"
                    }
                },
                div {
                    class: "files-breadcrumbs",
                    div {
                        class: "crumb",
                        IconElement {
                            icon: Icon::Home,
                        },
                        p {
                            "Home",
                        }
                    },
                    div {
                        class: "crumb",
                        p {
                            "Folder 1"
                        }
                    },
                    div {
                        class: "crumb",
                        p {
                            "Folder 3"
                        }
                    },
                },
                div {
                    class: "files-list",
                    Folder {
                        text: "Fake Folder 1".into()
                    },
                    File {
                        text: "Fake File".into()
                    },
                    File {
                        text: "fake_2.png".into()
                    },
                    Folder {
                        text: "New Fake".into(),
                    }
                }
            }
        }
    ))
}
