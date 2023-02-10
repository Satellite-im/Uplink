use dioxus::prelude::*;
use kit::{
    elements::{button::Button, switch::Switch},
    icons::Icon,
};
use shared::language::get_local_text;

use crate::{components::settings::ExtensionSetting, state::State};

#[allow(non_snake_case)]
pub fn ExtensionSettings(cx: Scope) -> Element {
    let state = use_shared_state::<State>(cx)?;

    let open_folder = get_local_text("settings-extensions.open-extensions-folder");
    cx.render(rsx!(
        div {
            id: "settings-extensions",
            aria_label: "settings-extensions",
            Button {
                icon: Icon::FolderOpen,
                text: open_folder,
                aria_label: "open-extensions-folder-button".into(),
            },
            state.read().ui.extensions.keys().map(|name| rsx!(
                ExtensionSetting {
                    title: name.clone(),
                    author: "Nobody#1345".into(),
                    description: "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.".into(),
                    Switch {}
                }
            ))
        }
    ))
}
