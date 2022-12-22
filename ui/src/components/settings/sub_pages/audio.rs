use dioxus::prelude::*;
use kit::elements::switch::Switch;

use crate::{components::settings::SettingSection, utils::language::{get_local_text}};

#[allow(non_snake_case)]
pub fn AudioSettings(cx: Scope) -> Element {
    cx.render(rsx!(
        div {
            id: "settings-audio",
            SettingSection {
                section_label: get_local_text("settings-audio.call-timer"),
                section_description: get_local_text("settings-audio.call-timer-description"),
                Switch {}
            }
        }
    ))
}
