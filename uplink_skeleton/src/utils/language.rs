use std::collections::HashMap;

use dioxus::prelude::{use_context, Scope};
use fluent_templates::{LanguageIdentifier, once_cell::sync::Lazy};
use unic_langid::langid;
use warp::sync::RwLock;

use crate::state::{State, Action};

const US_ENGLISH: LanguageIdentifier = langid!("en-US");
const BR_PORTUGUESE: LanguageIdentifier = langid!("pt-BR");
pub static APP_LANG: Lazy<RwLock<LanguageIdentifier>> =
    Lazy::new(|| RwLock::new(US_ENGLISH));
    
pub fn change_language( cx: Scope, new_language: String) {
    let state = use_context::<State>(&cx).unwrap();
    let app_languages = HashMap::from([
        (US_ENGLISH.to_string(), US_ENGLISH),
        (BR_PORTUGUESE.to_string(), BR_PORTUGUESE),
     ]);
     let new_language_identifier = 
                app_languages.get(new_language.as_str()); 

    match new_language_identifier {
        Some(new_lang) => {
            *APP_LANG.write() = new_lang.clone();
            state.write().mutate(Action::SetLanguage(new_language.to_owned()));
        }
        None =>  {
            *APP_LANG.write() = US_ENGLISH; 
            state.write().mutate(Action::SetLanguage(US_ENGLISH.to_string()));
        }
    }
}

pub fn load_language_selected_by_user(cx: Scope) {
    let state = use_context::<State>(&cx).unwrap();
    let user_lang_saved = state.read().settings.language.clone();
    change_language(cx, user_lang_saved);
}