use std::collections::HashMap;

use fluent_templates::{once_cell::sync::Lazy, LanguageIdentifier, Loader};
use unic_langid::langid;
use warp::sync::RwLock;

use crate::LOCALES;

pub const US_ENGLISH: (LanguageIdentifier, &str) = (langid!("en-US"), "English (USA)");
const BR_PORTUGUESE: (LanguageIdentifier, &str) = (langid!("pt-BR"), "Português (Brasil)");
const PT_PORTUGUESE: (LanguageIdentifier, &str) = (langid!("pt-PT"), "Português (Portugal)");
const MX_SPANISH: (LanguageIdentifier, &str) = (langid!("es-MX"), "Español (México)");
static APP_LANG: Lazy<RwLock<(LanguageIdentifier, &str)>> = Lazy::new(|| RwLock::new(US_ENGLISH));

pub fn change_language(new_language: String) -> String {
    let app_languages = HashMap::from([
        (US_ENGLISH.1, US_ENGLISH),
        (BR_PORTUGUESE.1, BR_PORTUGUESE),
        (PT_PORTUGUESE.1, PT_PORTUGUESE),
        (MX_SPANISH.1, MX_SPANISH),
    ]);
    let new_language_identifier = app_languages.get(new_language.as_str());

    match new_language_identifier {
        Some(new_lang) => {
            *APP_LANG.write() = new_lang.clone();
            new_lang.1.to_string()
        }
        None => {
            *APP_LANG.write() = US_ENGLISH;
            US_ENGLISH.1.to_string()
        }
    }
}

pub fn get_available_languages() -> Vec<String> {
    vec![
        US_ENGLISH.1.to_string(),
        BR_PORTUGUESE.1.to_string(),
        PT_PORTUGUESE.1.to_string(),
        MX_SPANISH.1.to_string(),
    ]
}

pub fn get_local_text(text: &str) -> String {
    LOCALES.lookup(&APP_LANG.read().0, text).unwrap_or_default()
}
