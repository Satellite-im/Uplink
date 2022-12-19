use std::collections::HashMap;

use fluent_templates::{LanguageIdentifier, once_cell::sync::Lazy};
use unic_langid::langid;
use warp::sync::RwLock;

const US_ENGLISH: LanguageIdentifier = langid!("en-US");
const BR_PORTUGUESE: LanguageIdentifier = langid!("pt-BR");
pub static APP_LANG: Lazy<RwLock<LanguageIdentifier>> =
    Lazy::new(|| RwLock::new(US_ENGLISH));
    
pub fn change_language(new_language: String) -> String {
    let app_languages = HashMap::from([
        (US_ENGLISH.to_string(), US_ENGLISH),
        (BR_PORTUGUESE.to_string(), BR_PORTUGUESE),
     ]);
     let new_language_identifier = 
                app_languages.get(new_language.as_str()); 

    match new_language_identifier {
        Some(new_lang) => {
            *APP_LANG.write() = new_lang.clone();
            return new_lang.to_string();
        }
        None =>  {
            *APP_LANG.write() = US_ENGLISH;
            return US_ENGLISH.to_string();
        }
    }
}