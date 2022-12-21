use dioxus::prelude::*;
use kit::{
    elements::{button::Button, Appearance},
    icons::Icon,
};

use crate::components::settings::SettingSection;

#[allow(non_snake_case)]
pub fn PrivacySettings(cx: Scope) -> Element {
    cx.render(rsx!(
        div {
            id: "settings-privacy",
            SettingSection {
                section_label: "Backup Recovery Phrase".into(),
                section_description: "Back this phrase up! Along with your password this represents your account. If you lose it, we can't help you get it back.".into(),
                Button {
                    text: "Backup Phrase".into(),
                    appearance: Appearance::Secondary,
                    icon: Icon::DocumentText,
                }
            },
        }
    ))
}
