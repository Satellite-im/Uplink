pub mod settings {
    use dioxus::prelude::*;

    use crate::layouts::chat::RouteInfo;

    #[derive(PartialEq, Props)]
    pub struct Props {
        route_info: RouteInfo,
    }

    #[allow(non_snake_case)]
    pub fn SettingsPage(cx: Scope<Props>) -> Element {
        cx.render(rsx!(
            div {
                id: "settings-page",
                
            }
        ))
    }
}