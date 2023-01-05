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

#[derive(PartialEq, Props)]
pub struct Props {
    route_info: RouteInfo,
}

#[allow(non_snake_case)]
pub fn SettingsLayout(cx: Scope<Props>) -> Element {
    let to = use_state(cx, || Page::Profile);

    cx.render(rsx!(
        div {
            id: "settings-layout",
            span {
                class: "full-width-on-mobile",
                Sidebar {
                    route_info: cx.props.route_info.clone(),
                    onpress: move |p| {
                        to.set(p);
                    },
                },
            },
            span {
                class: "hide-on-mobile",
                span {
                    id: "content",
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
    ))
}
