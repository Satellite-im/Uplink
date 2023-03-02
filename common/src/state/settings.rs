use crate::language::US_ENGLISH;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Settings {
    // Selected Language
    #[serde(default = "default_lang")]
    pub language: String,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            language: default_lang(),
        }
    }
}

fn default_lang() -> String {
    US_ENGLISH.1.to_string()
}
