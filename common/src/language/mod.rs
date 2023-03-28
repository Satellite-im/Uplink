use std::collections::HashMap;

use fluent_templates::{
    fluent_bundle::FluentValue, once_cell::sync::Lazy, LanguageIdentifier, Loader,
};
use unic_langid::langid;
use warp::sync::RwLock;

use crate::LOCALES;

pub const US_ENGLISH: (LanguageIdentifier, &str) = (langid!("en-US"), "English (USA)");

static LANGUAGES: Lazy<HashMap<String, (LanguageIdentifier, &'static str)>> = Lazy::new(|| {
    let mut map = HashMap::new();

    let add = |map: &mut HashMap<String, (LanguageIdentifier, &'static str)>,
               lang: &(LanguageIdentifier, &'static str)| {
        map.insert(lang.1.to_string(), lang.to_owned());
    };

    add(&mut map, &US_ENGLISH);
    add(&mut map, &(langid!("pt-BR"), "Português (Brasil)"));
    add(&mut map, &(langid!("pt-PT"), "Português (Portugal)"));
    add(&mut map, &(langid!("es-MX"), "Español (México)"));
    add(&mut map, &(langid!("de"), "Deutsch"));
    map
});

static APP_LANG: Lazy<RwLock<(LanguageIdentifier, &str)>> = Lazy::new(|| RwLock::new(US_ENGLISH));

pub fn change_language(new_language: String) -> String {
    let new_language_identifier = LANGUAGES.get(&new_language);

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
    let mut v: Vec<String> = LANGUAGES.keys().cloned().collect();
    v.sort();
    v
}

pub fn get_local_text(text: &str) -> String {
    LOCALES.lookup(&APP_LANG.read().0, text).unwrap_or_default()
}

// Looks and formats a local text using the given args
pub fn get_local_text_with_args<T: AsRef<str>>(
    text: &str,
    args: &HashMap<T, FluentValue>,
) -> String {
    LOCALES
        .lookup_with_args(&APP_LANG.read().0, text, args)
        .unwrap_or_default()
}

pub fn get_local_text_args_builder<F, T: AsRef<str>>(text: &str, builder: F) -> String
where
    F: FnOnce(&mut HashMap<T, FluentValue>),
{
    let args = {
        let mut map = HashMap::new();
        builder(&mut map);
        map
    };
    LOCALES
        .lookup_with_args(&APP_LANG.read().0, text, &args)
        .unwrap_or_default()
}
