use dioxus::prelude::*;
use ui_kit::{elements::input::{Input, Options}, icons::Icon, components::nav::Nav, layout::sidebar::Sidebar};

#[allow(non_snake_case)]
pub fn PrivacySettings(cx: Scope) -> Element {
    cx.render(rsx!(
        div {
            id: "settings-privacy",
            p {
                "Settings Content Privacy Page"
            }
        }
    ))
}
