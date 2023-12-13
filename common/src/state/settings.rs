use dioxus::prelude::*;
use dioxus_desktop::tao::keyboard::ModifiersState;
use std::collections::HashMap;

use crate::language::get_id_of;
use crate::language::US_ENGLISH;
use serde::{Deserialize, Serialize};
use warp::crypto::DID;

#[derive(Eq, PartialEq, Hash, Debug, Clone, Deserialize, Serialize)]
pub enum GlobalShortcut {
    ToggleMute,
    ToggleDeafen,
    IncreaseFontSize,
    DecreaseFontSize,
}

#[derive(Eq, PartialEq, Debug, Clone, Deserialize, Serialize)]
pub struct Shortcut {
    pub keys: Vec<KeyCode>,             // Keys required
    pub modifiers: Vec<ModifiersState>, // Modifier keys required
    pub system_shortcut: bool, // Determines if the shortcut should work system-wide i.e. even when uplink is not in focus
}

impl Shortcut {
    pub fn get_keys_and_modifiers_as_string(&self) -> Vec<String> {
        let key_code_strs: Vec<String> = self
            .keys
            .iter()
            .map(|key_code| {
                match key_code {
                    KeyCode::V => "v",
                    KeyCode::A => "a",
                    KeyCode::M => "m",
                    KeyCode::D => "d",
                    KeyCode::EqualSign => "=",
                    KeyCode::Subtract => "-",
                    _ => "unknown",
                    // ... Add other KeyCodes here
                }
                .to_string()
            })
            .collect();

        let mut modifier_strs: Vec<String> = self
            .modifiers
            .iter()
            .map(|modifier| {
                match modifier.clone() {
                    ModifiersState::SUPER => "command",
                    ModifiersState::SHIFT => "shift",
                    ModifiersState::CONTROL => "control",
                    ModifiersState::ALT => "alt",
                    _ => "unknown",
                    // ... Add other modifiers here
                }
                .to_string()
            })
            .collect();

        modifier_strs.extend(key_code_strs);

        modifier_strs
    }
}

impl From<(Vec<KeyCode>, Vec<ModifiersState>, bool)> for Shortcut {
    fn from(shortcut_tup: (Vec<KeyCode>, Vec<ModifiersState>, bool)) -> Self {
        Shortcut {
            keys: shortcut_tup.0,
            modifiers: shortcut_tup.1,
            system_shortcut: shortcut_tup.2,
        }
    }
}

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
    pub pause_global_keybinds: bool,
    pub keybinds: Vec<(GlobalShortcut, Shortcut)>,
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
            pause_global_keybinds: false,
            keybinds: super::default_keybinds::get_default_keybinds(),
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
