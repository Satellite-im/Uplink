use dioxus::prelude::*;
use kit::elements::{button::Button, switch::Switch};

use crate::{components::settings::SettingSection, utils::language::get_local_text};

#[allow(non_snake_case)]
pub fn FilesSettings(cx: Scope) -> Element {
    cx.render(rsx!(
        div {
            id: "settings-files",
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
                    appearance: kit::elements::Appearance::Secondary,
                    icon: kit::icons::Icon::FolderOpen,
                    onpress: |_| {
                    }
                }
            },
        }
    ))
}
