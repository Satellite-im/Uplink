use dioxus::prelude::*;
use kit::elements::switch::Switch;
use shared::language::get_local_text;
use warp::logging::tracing::log;

use crate::components::settings::SettingSection;

#[allow(non_snake_case)]
pub fn AudioSettings(cx: Scope) -> Element {
    log::debug!("Audio settings page rendered.");
    cx.render(rsx!(
        div {
            id: "settings-audio",
            aria_label: "settings-audio",
            SettingSection {
                section_label: get_local_text("settings-audio.call-timer"),
                section_description: get_local_text("settings-audio.call-timer-description"),
                Switch {}
            }
        }
    ))
}
