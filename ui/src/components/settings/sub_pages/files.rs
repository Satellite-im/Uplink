use dioxus::prelude::*;
use kit::elements::{button::Button, switch::Switch};
use shared::language::get_local_text;
use warp::logging::tracing::log;

use crate::components::settings::SettingSection;

#[allow(non_snake_case)]
pub fn FilesSettings(cx: Scope) -> Element {
    log::debug!("Files settings page rendered.");
    cx.render(rsx!(
        div {
            id: "settings-files",
            aria_label: "settings-files",
            SettingSection {
                section_label: get_local_text("settings-files.local-sync"),
                section_description: get_local_text("settings-files.local-sync-description"),
                Switch {

                }
            },
            SettingSection {
                section_label: get_local_text("settings-files.open-sync-folder"),
                section_description: get_local_text("settings-files.open-sync-folder-description"),
                Button {
                    text: get_local_text("settings-files.open-sync-folder"),
                    aria_label: "open-sync-folder-button".into(),
                    appearance: kit::elements::Appearance::Secondary,
                    icon: kit::icons::Icon::FolderOpen,
                    onpress: |_| {
                    }
                }
            },
        }
    ))
}
