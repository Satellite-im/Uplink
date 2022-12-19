use dioxus::prelude::*;
use ui_kit::{elements::{switch::Switch, button::Button, Appearance}, icons::Icon};

use crate::{components::settings::SettingSection, utils::language::change_language};

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
            },
            SettingSection {
                section_label: "en-US".into(),
                section_description: "Change lang to en-US".into(),
                Button {
                    text: "en-US".into(),
                    appearance: Appearance::Secondary,
                    icon: Icon::CodeBracketSquare,
                    onpress: move |_| {
                        change_language(cx, "en-US".to_owned());
                        use_router(&cx).replace_route("/settings", None, None);
                    }
                }
            },
            SettingSection {
                section_label: "pt-BR".into(),
                section_description: "Change lang to pt-BR".into(),
                Button {
                    text: "pt-BR".into(),
                    appearance: Appearance::Secondary,
                    icon: Icon::CodeBracketSquare,
                    onpress: move |_| {
                        change_language(cx, "pt-BR".to_owned());
                        use_router(&cx).replace_route("/settings", None, None);
                    }
                }
            },
        }
    ))
}
