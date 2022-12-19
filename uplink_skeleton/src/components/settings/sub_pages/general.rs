use dioxus::prelude::*;
use ui_kit::{elements::{switch::Switch, select::Select }};

use crate::{components::settings::SettingSection, utils::language::{change_language, get_available_languages}, state::{State, Action}};

#[allow(non_snake_case)]
pub fn GeneralSettings(cx: Scope) -> Element {    
    let state = use_context::<State>(&cx).unwrap();
    let initial_lang_value = state.read().settings.language.clone();

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
                section_label: "App language".into(),
                section_description: "Change language".into(),
                Select {
                    initial_value: initial_lang_value,
                    options: get_available_languages(),
                    onselect: move |value| {
                        let new_app_lang = change_language(value);
                        state.write().mutate(Action::SetLanguage(new_app_lang));
                    }
                }
            },
        }
    ))
}
