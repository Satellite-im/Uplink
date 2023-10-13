use common::language::get_local_text;
use dioxus::prelude::*;
use kit::elements::switch::Switch;
use warp::logging::tracing::log;

use crate::components::settings::SettingSection;

#[allow(non_snake_case)]
pub fn Messages(cx: Scope) -> Element {
    log::trace!("Messages settings page rendered.");

    cx.render(rsx!(
        div {
            id: "settings-messages",
            aria_label: "settings-messages",
            SettingSection {
                section_label: get_local_text("settings-messages.emoji-conversion"),
                section_description: get_local_text("settings-messages.emoji-conversion-description"),
                Switch {}
            },
            SettingSection {
                section_label: get_local_text("settings-messages.markdown-support"),
                section_description: get_local_text("settings-messages.markdown-support-description"),
                Switch {}
            }
        }
    ))
}
