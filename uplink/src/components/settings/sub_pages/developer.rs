use dioxus::prelude::*;
use fluent_templates::Loader;
use ui_kit::{elements::{switch::Switch, Appearance, button::Button}, icons::Icon};

use crate::{components::settings::SettingSection, state::State, utils::language::APP_LANG, LOCALES};


#[allow(non_snake_case)]
pub fn DeveloperSettings(cx: Scope) -> Element {
    let state = use_context::<State>(&cx).unwrap();

    let app_lang = &*APP_LANG.read();
    let developer_mode_label = LOCALES
        .lookup(app_lang, "settings-developer.developer-mode")
        .unwrap_or_default();
    let developer_mode_description = LOCALES
        .lookup(app_lang, "settings-developer.developer-mode-description")
        .unwrap_or_default();

    let open_codebase_label = LOCALES
        .lookup(app_lang, "settings-developer.open-codebase")
        .unwrap_or_default();
    let open_codebase_description = LOCALES
        .lookup(app_lang, "settings-developer.open-codebase-description")
        .unwrap_or_default();

    let open_cache_label = LOCALES
        .lookup(app_lang, "settings-developer.open-cache")
        .unwrap_or_default();
    let open_cache_description = LOCALES
        .lookup(app_lang, "settings-developer.open-cache-description")
        .unwrap_or_default();
    let open_cache_folder = LOCALES
        .lookup(app_lang, "settings-developer.open-cache-folder")
        .unwrap_or_default();

    let compress_cache_label = LOCALES
        .lookup(app_lang, "settings-developer.compress-download-cache")
        .unwrap_or_default();
    let compress_cache_description = LOCALES
        .lookup(app_lang, "settings-developer.compress-download-cache-description")
        .unwrap_or_default();
    let compress_button = LOCALES
        .lookup(app_lang, "settings-developer.compress")
        .unwrap_or_default();

    let clear_cache_label = LOCALES
        .lookup(app_lang, "settings-developer.clear-cache")
        .unwrap_or_default();
    let clear_cache_description = LOCALES
        .lookup(app_lang, "settings-developer.clear-cache-description")
        .unwrap_or_default();
    let clear_button = LOCALES
        .lookup(app_lang, "settings-developer.clear")
        .unwrap_or_default();

    cx.render(rsx!(
        div {
            id: "settings-developer",
            SettingSection {
                section_label: developer_mode_label,
                section_description: developer_mode_description,
                Switch {
                    
                }
            },
            SettingSection {
                section_label: open_codebase_label.clone(),
                section_description: open_codebase_description,
                Button {
                    text: open_codebase_label,
                    appearance: Appearance::Secondary,
                    icon: Icon::CodeBracketSquare,
                    onpress: |_| {
                        let _ = open::that("https://github.com/Satellite-im/Uplink-UI_Kit/tree/main/uplink_skeleton");
                    }
                }
            },
            SettingSection {
                section_label: open_cache_label,
                section_description: open_cache_description,
                Button {
                    text: open_cache_folder,
                    appearance: Appearance::Secondary,
                    icon: Icon::FolderOpen,
                    onpress: |_| {
                        let cache_path = dirs::home_dir()
                            .unwrap_or_default()
                            .join(".uplink/")
                            .into_os_string()
                            .into_string()
                            .unwrap_or_default();
                        let _ = opener::open(&cache_path);
                    }
                }
            },
            SettingSection {
                section_label: compress_cache_label,
                section_description: compress_cache_description,
                Button {
                    text: compress_button,
                    appearance: Appearance::Secondary,
                    icon: Icon::ArchiveBoxArrowDown,
                    onpress: |_| {
                    }
                }
            },
            SettingSection {
                section_label: clear_cache_label,
                section_description: clear_cache_description,
                Button {
                    text: clear_button,
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
