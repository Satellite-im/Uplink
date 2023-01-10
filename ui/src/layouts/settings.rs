use dioxus::prelude::*;

use crate::components::{
    chat::RouteInfo,
    settings::{
        sidebar::{Page, Sidebar},
        sub_pages::{
            audio::AudioSettings, developer::DeveloperSettings, extensions::ExtensionSettings,
            files::FilesSettings, general::GeneralSettings, privacy::PrivacySettings,
            profile::ProfileSettings,
        },
    },
};

use kit::layout::topbar::Topbar;

#[derive(PartialEq, Props)]
pub struct Props {
    route_info: RouteInfo,
}

#[allow(non_snake_case)]
pub fn SettingsLayout(cx: Scope<Props>) -> Element {
    let to = use_state(cx, || Page::Profile);
    let showSidebar = use_state(&cx, || true);

    cx.render(rsx!(
        div {
            id: "settings-layout",
            if showSidebar == false {
                cx.render(rsx!{
                    div {
                        aria_label: "settings-layout",
                        div {
                            class: "hide-on-mobile",
                            Sidebar {
                                route_info: cx.props.route_info.clone(),
                                onpress: move |p| {
                                    showSidebar.set(false);
                                    to.set(p);
                                },
                            },
                        },
                        div {
                            class: "full-width",
                            div {
                                id: "top-bar",
                                class: "hide-on-desktop",
                                Topbar {
                                    with_back_button: true,
                                    onback: move |_| {
                                        showSidebar.set(true);
                                    }
                                },
                            },
                            div {
                                id: "content",
                                class: "full-width",
                                match to.get() {
                                    Page::Profile       => cx.render(rsx! (
                                        ProfileSettings {}
                                    )),
                                    Page::General       => cx.render(rsx! (
                                        GeneralSettings {}
                                    )),
                                    Page::Audio         => cx.render(rsx! (
                                        AudioSettings {}
                                    )),
                                    Page::Privacy       => cx.render(rsx! (
                                        PrivacySettings {}
                                    )),
                                    Page::Files         => cx.render(rsx! (
                                        FilesSettings {}
                                    )),
                                    Page::Extensions    => cx.render(rsx! (
                                        ExtensionSettings {}
                                    )),
                                    Page::Developer     => cx.render(rsx! (
                                        DeveloperSettings {}
                                    ))
                                }
                            }
                        },
                    }
                })
            } else {
                cx.render(rsx!{
                    div {
                        aria_label: "settings-layout",
                        div {
                            class: "full-width-on-mobile",
                            Sidebar {
                                route_info: cx.props.route_info.clone(),
                                onpress: move |p| {
                                    showSidebar.set(false);
                                    to.set(p);
                                },
                            },
                        },
                        div {
                            class: "full-width hide-on-mobile",
                            div {
                                id: "content",
                                class: "full-width hidden-on-mobile",
                                match to.get() {
                                    Page::Profile       => cx.render(rsx! (
                                        ProfileSettings {}
                                    )),
                                    Page::General       => cx.render(rsx! (
                                        GeneralSettings {}
                                    )),
                                    Page::Audio         => cx.render(rsx! (
                                        AudioSettings {}
                                    )),
                                    Page::Privacy       => cx.render(rsx! (
                                        PrivacySettings {}
                                    )),
                                    Page::Files         => cx.render(rsx! (
                                        FilesSettings {}
                                    )),
                                    Page::Extensions    => cx.render(rsx! (
                                        ExtensionSettings {}
                                    )),
                                    Page::Developer     => cx.render(rsx! (
                                        DeveloperSettings {}
                                    ))
                                }
                            }
                        },
                    },
                })
            }
        }
    ))
}
