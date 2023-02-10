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
            state.read().ui.extensions.values().map(|ext| {
                let details = ext.extension.details();
                rsx!(
                    ExtensionSetting {
                        title: details.meta.pretty_name.to_owned(),
                        author: details.meta.author.to_owned(),
                        description: details.meta.description.to_owned(),
                        Switch {}
                    }
                )
            })
        }
    ))
}
