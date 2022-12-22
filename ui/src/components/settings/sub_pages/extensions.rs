use dioxus::prelude::*;
use kit::{
    elements::{button::Button, switch::Switch},
    icons::Icon,
};

use crate::{components::settings::ExtensionSetting, utils::language::get_local_text};

#[allow(non_snake_case)]
pub fn ExtensionSettings(cx: Scope) -> Element {
    cx.render(rsx!(
        div {
            id: "settings-extensions",
            Button {
                icon: Icon::FolderOpen,
                text: get_local_text("settings-extensions.open-extensions-folder"),
            },
            ExtensionSetting {
                title: get_local_text("settings-extensions.placeholder"),
                author: "Nobody#1345".into(),
                description: "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.".into(),
                Switch {}
            }
        }
    ))
}
