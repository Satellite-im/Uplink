use dioxus::prelude::*;
use fluent_templates::Loader;
use ui_kit::elements::switch::Switch;

use crate::{components::settings::SettingSection, LOCALES, utils::language::APP_LANG};

#[allow(non_snake_case)]
pub fn AudioSettings(cx: Scope) -> Element {
    let app_lang = &*APP_LANG.read();
    let section_label_text = LOCALES
        .lookup(app_lang, "settings-audio.call-timer")
        .unwrap_or_default();

    let section_description = LOCALES
        .lookup(app_lang, "settings-audio.call-timer-description")
        .unwrap_or_default();

    cx.render(rsx!(
        div {
            id: "settings-audio",
            SettingSection {
                section_label: section_label_text,
                section_description: section_description,
                Switch {}
            }
        }
    ))
}
