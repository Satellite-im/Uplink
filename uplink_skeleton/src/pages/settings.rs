pub mod settings {
    use dioxus::prelude::*;

    use crate::layouts::{chat::RouteInfo, settings::{sidebar::{SettingsSidebar as Sidebar, Page}, sub_pages::{general::GeneralSettings, audio::AudioSettings, privacy::PrivacySettings, extensions::ExtensionSettings, developer::DeveloperSettings}}};

    #[derive(PartialEq, Props)]
    pub struct Props {
        route_info: RouteInfo,
    }

    pub fn get_page<'a>(cx: &'a Scope<'a, Props>, to: String) -> Element<'a> {
        match to.as_str() {
            "general" => cx.render(rsx!(GeneralSettings {})),
            _ => cx.render(rsx!(GeneralSettings {})),
        }
    }

    #[allow(non_snake_case)]
    pub fn SettingsPage(cx: Scope<Props>) -> Element {
        let to = use_state(&cx, || Page::General);

        cx.render(rsx!(
            div {
                id: "settings-page",
                Sidebar {
                    route_info: cx.props.route_info.clone(),
                    onpress: move |p| {
                        to.set(p);
                    }
                },
                match to.get() {
                    Page::General => cx.render(rsx! (
                        GeneralSettings{}
                    )),
                    Page::Audio => cx.render(rsx! (
                        AudioSettings{}
                    )),
                    Page::Privacy => cx.render(rsx! (
                        PrivacySettings{}
                    )),
                    Page::Extensions => cx.render(rsx! (
                        ExtensionSettings{}
                    )),
                    Page::Developer => cx.render(rsx! (
                        DeveloperSettings{}
                    ))
                }
            }
        ))
    }
}