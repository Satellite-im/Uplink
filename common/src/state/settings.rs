use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Settings {
    // Selected Language
    #[serde(default)]
    pub language: String,
}

impl Settings {
    pub fn new() -> Self {
        Settings {
            language: String::from("English (USA)"),
        }
    }
}
