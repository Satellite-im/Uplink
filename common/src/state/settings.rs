use std::collections::HashMap;

use crate::language::get_id_of;
use crate::language::US_ENGLISH;
use serde::{Deserialize, Serialize};
use warp::crypto::DID;

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Settings {
    // Selected Language
    // This is the name of the language
    // use language_id() to get the id
    #[serde(default = "default_lang")]
    pub language: String,
    pub update_available: Option<String>,
    // if the user declines an update, save the version here and don't prompt them anymore
    pub update_dismissed: Option<String>,
    pub input_device: Option<String>,
    pub output_device: Option<String>,
    #[serde(default = "default_font_scale")]
    font_scale: f32,
    pub user_volumes: HashMap<DID, f32>,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            language: default_lang(),
            update_dismissed: None,
            update_available: None,
            input_device: None,
            output_device: None,
            font_scale: 1.0,
            user_volumes: HashMap::new(),
        }
    }
}

impl Settings {
    pub fn language_id(&self) -> String {
        get_id_of(&self.language)
    }
}

fn default_font_scale() -> f32 {
    1.0_f32
}

fn default_lang() -> String {
    US_ENGLISH.1.to_string()
}

impl Settings {
    pub fn font_scale(&self) -> f32 {
        self.font_scale
    }
    pub fn set_font_scale(&mut self, scale: f32) {
        self.font_scale = scale;
    }
}
