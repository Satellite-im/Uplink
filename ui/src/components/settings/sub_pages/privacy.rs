/*
use common::icons::outline::Shape as Icon;
use common::language::get_local_text;
use dioxus::prelude::*;
use kit::elements::{button::Button, Appearance};
use tracing::log;

use crate::components::settings::SettingSection;

#[allow(non_snake_case)]
pub fn PrivacySettings() -> Element {
    log::trace!("Privacy settings page rendered.");
    rsx!(
        div {
            id: "settings-privacy",
            aria_label: "settings-privacy",
            SettingSection {
                section_label: get_local_text("settings-privacy.backup-recovery-phrase"),
                section_description: get_local_text("settings-privacy.backup-phrase-description"),
                Button {
                    text: get_local_text("settings-privacy.backup-phrase"),
                    aria_label: "backup-phrase-button".to_string(),
                    appearance: Appearance::Secondary,
                    icon: Icon::DocumentText,
                }
            },
        }
    ))
}
*/
