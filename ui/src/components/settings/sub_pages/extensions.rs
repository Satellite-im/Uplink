use dioxus::prelude::*;
use kit::{
    elements::{button::Button, switch::Switch},
    icons::Icon,
};

use crate::components::settings::ExtensionSetting;

#[allow(non_snake_case)]
pub fn ExtensionSettings(cx: Scope) -> Element {
    cx.render(rsx!(
        div {
            id: "settings-extensions",
            Button {
                icon: Icon::FolderOpen,
                text: "Open Extensions Folder".into(),
            },
            ExtensionSetting {
                title: "Placeholder".into(),
                author: "Nobody#1345".into(),
                description: "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.".into(),
                Switch {}
            }
        }
    ))
}
