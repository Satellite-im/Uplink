use dioxus::prelude::*;
use ui_kit::{elements::input::{Input, Options}, icons::Icon, components::nav::Nav, layout::sidebar::Sidebar};

#[allow(non_snake_case)]
pub fn DeveloperSettings(cx: Scope) -> Element {
    cx.render(rsx!(
        div {
            id: "settings-developer",
            p {
                "Settings Content Developer Page"
            }
        }
    ))
}
