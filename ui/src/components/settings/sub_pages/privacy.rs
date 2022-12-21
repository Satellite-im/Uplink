use dioxus::prelude::*;
use fluent_templates::Loader;
use kit::{
    elements::{button::Button, Appearance},
    icons::Icon,
};

use crate::{components::settings::SettingSection, utils::language::APP_LANG, LOCALES};

#[allow(non_snake_case)]
pub fn PrivacySettings(cx: Scope) -> Element {
    let app_lang = &*APP_LANG.read();
    let section_label_text = LOCALES
        .lookup(app_lang, "settings-privacy.backup-recovery-phrase")
        .unwrap_or_default();

    let section_description = LOCALES
        .lookup(app_lang, "settings-privacy.backup-phrase-description")
        .unwrap_or_default();

    let button_text = LOCALES
        .lookup(app_lang, "settings-privacy.backup-phrase")
        .unwrap_or_default();

    cx.render(rsx!(
        div {
            id: "settings-privacy",
            SettingSection {
                section_label: section_label_text,
                section_description: section_description,
                Button {
                    text: button_text,
                    appearance: Appearance::Secondary,
                    icon: Icon::DocumentText,
                }
            },
        }
    ))
}
