use dioxus::prelude::*;
use kit::elements::switch::Switch;

use crate::components::settings::SettingSection;

#[allow(non_snake_case)]
pub fn AudioSettings(cx: Scope) -> Element {
    cx.render(rsx!(
        div {
            id: "settings-audio",
            SettingSection {
                section_label: "Call Timer".into(),
                section_description: "When enabled a timer will display when you're in a call showing it's duration.".into(),
                Switch {}
            }
        }
    ))
}
