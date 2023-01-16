use dioxus::prelude::*;
use kit::{
    elements::{button::Button, Appearance},
    icons::Icon,
};
use shared::language::get_local_text;

use crate::{components::settings::SettingSection, logger::logger::Logger};

#[allow(non_snake_case)]
pub fn PrivacySettings(cx: Scope) -> Element {
    Logger::load().info("Privacy settings opened");
    cx.render(rsx!(
        div {
            id: "settings-privacy",
            aria_label: "settings-privacy",
            SettingSection {
                section_label: get_local_text("settings-privacy.backup-recovery-phrase"),
                section_description: get_local_text("settings-privacy.backup-phrase-description"),
                Button {
                    text: get_local_text("settings-privacy.backup-phrase"),
                    aria_label: "backup-phrase-button".into(),
                    appearance: Appearance::Secondary,
                    icon: Icon::DocumentText,
                }
            },
        }
    ))
}
