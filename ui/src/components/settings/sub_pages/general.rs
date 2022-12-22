use dioxus::prelude::*;
es/general.rs
use fermi::use_atom_ref;
use fluent_templates::Loader;

use kit::{elements::{switch::Switch, select::Select }};

use crate::{components::settings::SettingSection, utils::language::{change_language, get_available_languages, get_local_text}, state::{State, Action}};

#[allow(non_snake_case)]
pub fn GeneralSettings(cx: Scope) -> Element {    
    let state = use_shared_state::<State>(&cx)?;
    let initial_lang_value = state.read().settings.language.clone();
  
    cx.render(rsx!(
        div {
            id: "settings-general",
            SettingSection {
                section_label: get_local_text("settings.splash-screen"),
                section_description: get_local_text("settings.splash-screen-description"),
                Switch {
          
                }
            },
            SettingSection {
                section_label: get_local_text("settings.general-app-language"),
                section_description: get_local_text("settings.general-change-language"),
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
