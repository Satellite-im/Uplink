use common::{
    language::get_local_text,
    state::{Action, State},
};
use dioxus::prelude::*;
use kit::elements::switch::Switch;
use warp::logging::tracing::log;

use crate::components::settings::SettingSection;

#[allow(non_snake_case)]
pub fn Messages(cx: Scope) -> Element {
    log::trace!("Messages settings page rendered.");
    let state = use_shared_state::<State>(cx)?;
    cx.render(rsx!(
        div {
            id: "settings-messages",
            aria_label: "settings-messages",
            // the markdowns crate does something special to prevent it from converting :) to emoji within code segments and it's hard to 
            // separate the two. It can currently either do emoji + markdown or nothing. 
            // SettingSection {
            //     section_label: get_local_text("settings-messages.emoji-conversion"),
            //     section_description: get_local_text("settings-messages.emoji-conversion-description"),
            //     Switch {}
            // },
            SettingSection {
                section_label: get_local_text("settings-messages.markdown-support"),
                section_description: get_local_text("settings-messages.markdown-support-description"),
                Switch {
                    onflipped: move|flag| {
                        state.write().mutate(Action::SetTransformMarkdownText(flag));
                    }
                }
            }
        }
    ))
}
