pub mod settings {
    use dioxus::prelude::*;

    use crate::layouts::{chat::RouteInfo, settings::{sidebar::SettingsSidebar as Sidebar, sub_pages::general::GeneralSettings}};

    #[derive(PartialEq, Props)]
    pub struct Props {
        route_info: RouteInfo,
    }

    #[allow(non_snake_case)]
    pub fn SettingsPage(cx: Scope<Props>) -> Element {
        cx.render(rsx!(
            div {
                id: "settings-page",
                Sidebar {
                    route_info: cx.props.route_info.clone()
                },
                // TODO: render conditionally based on sidebar nav output
                GeneralSettings {}
            }
        ))
    }
}