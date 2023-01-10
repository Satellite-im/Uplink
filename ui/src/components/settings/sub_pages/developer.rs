use dioxus::prelude::*;

use kit::{
    elements::{button::Button, switch::Switch, Appearance},
    icons::Icon,
};
use shared::language::get_local_text;

use crate::{
    components::settings::SettingSection, config::Configuration, state::State,
};

#[allow(non_snake_case)]
pub fn DeveloperSettings(cx: Scope) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let mut config = Configuration::load_or_default();

    cx.render(rsx!(
        div {
            id: "settings-developer",
            aria_label: "settings-developer",
            SettingSection {
                section_label: get_local_text("settings-developer.developer-mode"),
                section_description: get_local_text("settings-developer.developer-mode-description"),
                Switch {
                    active: config.developer.developer_mode,
                    onflipped: move |value| {
                        config.set_developer_mode(value);
                    },
                }
            },
            SettingSection {
                section_label: get_local_text("settings-developer.open-codebase"),
                section_description: get_local_text("settings-developer.open-codebase-description"),
                Button {
                    text: get_local_text("settings-developer.open-codebase"),
                    aria_label: "open-codebase-button".into(),
                    appearance: Appearance::Secondary,
                    icon: Icon::CodeBracketSquare,
                    onpress: |_| {
                        let _ = open::that("https://github.com/Satellite-im/Uplink-UI_Kit/tree/main/uplink_skeleton");
                    }
                }
            },
            SettingSection {
                section_label: get_local_text("settings-developer.open-cache"),
                section_description: get_local_text("settings-developer.open-cache-description"),
                Button {
                    text: get_local_text("settings-developer.open-cache-folder"),
                    aria_label: "open-cache-folder-button".into(),
                    appearance: Appearance::Secondary,
                    icon: Icon::FolderOpen,
                    onpress: |_| {
                        let cache_path = dirs::home_dir()
                            .unwrap_or_default()
                            .join(".uplink/")
                            .into_os_string()
                            .into_string()
                            .unwrap_or_default();
                        let _ = opener::open(cache_path);
                    }
                }
            },
            SettingSection {
                section_label: get_local_text("settings-developer.compress-download-cache"),
                section_description: get_local_text("settings-developer.compress-download-cache-description"),
                Button {
                    text: get_local_text("settings-developer.compress"),
                    aria_label: "compress-button".into(),
                    appearance: Appearance::Secondary,
                    icon: Icon::ArchiveBoxArrowDown,
                    onpress: |_| {
                    }
                }
            },
            SettingSection {
                section_label: get_local_text("settings-developer.clear-cache"),
                section_description: get_local_text("settings-developer.clear-cache-description"),
                Button {
                    text: get_local_text("settings-developer.clear"),
                    aria_label: "clear-button".into(),
                    appearance: Appearance::Danger,
                    icon: Icon::Trash,
                    onpress: move |_| {
                        state.write().clear();
                    }
                }
            }
        }
    ))
}
