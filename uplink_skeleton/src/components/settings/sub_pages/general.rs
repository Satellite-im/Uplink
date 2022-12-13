use dioxus::prelude::*;
use ui_kit::elements::switch::Switch;

use crate::components::settings::SettingSection;

#[allow(non_snake_case)]
pub fn GeneralSettings(cx: Scope) -> Element {
    cx.render(rsx!(
        div {
            id: "settings-general",
            SettingSection {
                section_label: "Splash Screen".into(),
                section_description: "Disabling the splash screen could speed up load times.".into(),
                Switch {
                    
                }
            }
        }
    ))
}
