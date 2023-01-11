use std::collections::HashMap;

use fluent_templates::{once_cell::sync::Lazy, LanguageIdentifier, Loader};
use unic_langid::langid;
use warp::sync::RwLock;

use crate::LOCALES;

const US_ENGLISH: LanguageIdentifier = langid!("en-US");
const BR_PORTUGUESE: LanguageIdentifier = langid!("pt-BR");
const PT_PORTUGUESE: LanguageIdentifier = langid!("pt-PT");
const MX_SPANISH: LanguageIdentifier = langid!("es-MX");
static APP_LANG: Lazy<RwLock<LanguageIdentifier>> = Lazy::new(|| RwLock::new(US_ENGLISH));

pub fn change_language(new_language: String) -> String {
    let app_languages = HashMap::from([
        (US_ENGLISH.to_string(), US_ENGLISH),
        (BR_PORTUGUESE.to_string(), BR_PORTUGUESE),
        (PT_PORTUGUESE.to_string(), PT_PORTUGUESE),
        (MX_SPANISH.to_string(), MX_SPANISH),
    ]);
    let new_language_identifier = app_languages.get(new_language.as_str());

    match new_language_identifier {
        Some(new_lang) => {
            *APP_LANG.write() = new_lang.clone();
            new_lang.to_string()
        }
        None => {
            *APP_LANG.write() = US_ENGLISH;
            US_ENGLISH.to_string()
        }
    }
}

pub fn get_available_languages() -> Vec<String> {
    vec![
        US_ENGLISH.to_string(),
        BR_PORTUGUESE.to_string(),
        PT_PORTUGUESE.to_string(),
        MX_SPANISH.to_string(),
    ]
}

pub fn get_local_text(text: &str) -> String {
    LOCALES.lookup(&APP_LANG.read(), text).unwrap_or_default()
}
