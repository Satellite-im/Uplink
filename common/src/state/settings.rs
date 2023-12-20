use dioxus::prelude::*;
use dioxus_desktop::tao::keyboard::ModifiersState;
use std::collections::HashMap;
use std::fmt;

use crate::language::get_id_of;
use crate::language::US_ENGLISH;
use serde::{Deserialize, Serialize};
use warp::crypto::DID;

use super::State;

#[derive(Eq, PartialEq, Hash, Debug, Clone, Deserialize, Serialize)]
pub enum GlobalShortcut {
    ToggleMute,
    ToggleDeafen,
    IncreaseFontSize,
    DecreaseFontSize,
}

impl fmt::Display for GlobalShortcut {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            GlobalShortcut::ToggleMute => write!(f, "ToggleMute"),
            GlobalShortcut::ToggleDeafen => write!(f, "ToggleDeafen"),
            GlobalShortcut::IncreaseFontSize => write!(f, "IncreaseFontSize"),
            GlobalShortcut::DecreaseFontSize => write!(f, "DecreaseFontSize"),
        }
    }
}

#[derive(Eq, PartialEq, Debug, Clone, Deserialize, Serialize)]
pub struct Shortcut {
    pub keys: Vec<KeyCode>,             // Keys required
    pub modifiers: Vec<ModifiersState>, // Modifier keys required
    pub system_shortcut: bool, // Determines if the shortcut should work system-wide i.e. even when uplink is not in focus
}

impl Shortcut {
    pub fn get_system_shortcut(
        state: &UseSharedState<State>,
        global_shortcut: GlobalShortcut,
    ) -> bool {
        state
            .read()
            .settings
            .keybinds
            .iter()
            .find(|(gs, _)| *gs == global_shortcut)
            .map(|(_, sc)| sc.system_shortcut)
            .unwrap_or(false)
    }

    pub fn get_keys_and_modifiers_as_string(&self) -> Vec<String> {
        let key_code_strs: Vec<String> = self
            .keys
            .iter()
            .map(|key_code| key_code_to_str(key_code).to_string())
            .collect();

        let mut modifier_strs: Vec<String> = self
            .modifiers
            .iter()
            .map(|modifier| modifier_state_to_string(modifier.clone()))
            .collect();

        modifier_strs.extend(key_code_strs);

        modifier_strs
    }

    pub fn string_to_keycode_and_modifiers_state(
        keys_and_modifiers: Vec<String>,
    ) -> (Vec<KeyCode>, Vec<ModifiersState>) {
        let mut key_code_vec: Vec<KeyCode> = vec![];
        let mut modifiers_state_vec: Vec<ModifiersState> = vec![];

        for modifier_string in keys_and_modifiers.clone() {
            match modifier_string.as_str() {
                "Command" => modifiers_state_vec.push(ModifiersState::SUPER),
                "Meta" => modifiers_state_vec.push(ModifiersState::SUPER),
                "Shift" => modifiers_state_vec.push(ModifiersState::SHIFT),
                "Ctrl" => modifiers_state_vec.push(ModifiersState::CONTROL),
                "Alt" => modifiers_state_vec.push(ModifiersState::ALT),
                _ => (),
            }
        }

        for key_string in keys_and_modifiers {
            if key_code_vec.len() > 0 {
                break;
            }
            match key_string.as_str() {
                "KeyA" => key_code_vec.push(KeyCode::A),
                "KeyB" => key_code_vec.push(KeyCode::B),
                "KeyC" => key_code_vec.push(KeyCode::C),
                "KeyD" => key_code_vec.push(KeyCode::D),
                "KeyE" => key_code_vec.push(KeyCode::E),
                "KeyF" => key_code_vec.push(KeyCode::F),
                "KeyG" => key_code_vec.push(KeyCode::G),
                "KeyH" => key_code_vec.push(KeyCode::H),
                "KeyI" => key_code_vec.push(KeyCode::I),
                "KeyJ" => key_code_vec.push(KeyCode::J),
                "KeyK" => key_code_vec.push(KeyCode::K),
                "KeyL" => key_code_vec.push(KeyCode::L),
                "KeyM" => key_code_vec.push(KeyCode::M),
                "KeyN" => key_code_vec.push(KeyCode::N),
                "KeyO" => key_code_vec.push(KeyCode::O),
                "KeyP" => key_code_vec.push(KeyCode::P),
                "KeyQ" => key_code_vec.push(KeyCode::Q),
                "KeyR" => key_code_vec.push(KeyCode::R),
                "KeyS" => key_code_vec.push(KeyCode::S),
                "KeyT" => key_code_vec.push(KeyCode::T),
                "KeyU" => key_code_vec.push(KeyCode::U),
                "KeyV" => key_code_vec.push(KeyCode::V),
                "KeyW" => key_code_vec.push(KeyCode::W),
                "KeyX" => key_code_vec.push(KeyCode::X),
                "KeyY" => key_code_vec.push(KeyCode::Y),
                "KeyZ" => key_code_vec.push(KeyCode::Z),
                "Digit0" => key_code_vec.push(KeyCode::Num0),
                "Digit1" => key_code_vec.push(KeyCode::Num1),
                "Digit2" => key_code_vec.push(KeyCode::Num2),
                "Digit3" => key_code_vec.push(KeyCode::Num3),
                "Digit4" => key_code_vec.push(KeyCode::Num4),
                "Digit5" => key_code_vec.push(KeyCode::Num5),
                "Digit6" => key_code_vec.push(KeyCode::Num6),
                "Digit7" => key_code_vec.push(KeyCode::Num7),
                "Digit8" => key_code_vec.push(KeyCode::Num8),
                "Digit9" => key_code_vec.push(KeyCode::Num9),
                "Minus" => key_code_vec.push(KeyCode::Subtract),
                "Equal" => key_code_vec.push(KeyCode::EqualSign),
                "NumpadAdd" => key_code_vec.push(KeyCode::Add),
                "BracketLeft" => key_code_vec.push(KeyCode::OpenBracket),
                "BracketRight" => key_code_vec.push(KeyCode::CloseBraket),
                "Backslash" => key_code_vec.push(KeyCode::BackSlash),
                "Semicolon" => key_code_vec.push(KeyCode::Semicolon),
                // "Backquote" => key_code_vec.push(KeyCode::Apostrophe),
                "Quote" => key_code_vec.push(KeyCode::SingleQuote),
                "Comma" => key_code_vec.push(KeyCode::Comma),
                "Period" => key_code_vec.push(KeyCode::Period),
                "Slash" => key_code_vec.push(KeyCode::ForwardSlash),
                "Space" => key_code_vec.push(KeyCode::Space),
                _ => (),
            }
        }

        (key_code_vec, modifiers_state_vec)
    }
}

pub fn key_code_to_str(key_code: &KeyCode) -> &str {
    match key_code {
        KeyCode::A => "a",
        KeyCode::B => "b",
        KeyCode::C => "c",
        KeyCode::D => "d",
        KeyCode::E => "e",
        KeyCode::F => "f",
        KeyCode::G => "g",
        KeyCode::H => "h",
        KeyCode::I => "i",
        KeyCode::J => "j",
        KeyCode::K => "k",
        KeyCode::L => "l",
        KeyCode::M => "m",
        KeyCode::N => "n",
        KeyCode::O => "o",
        KeyCode::P => "p",
        KeyCode::Q => "q",
        KeyCode::R => "r",
        KeyCode::S => "s",
        KeyCode::T => "t",
        KeyCode::U => "u",
        KeyCode::V => "v",
        KeyCode::W => "w",
        KeyCode::X => "x",
        KeyCode::Y => "y",
        KeyCode::Z => "z",
        KeyCode::Num0 => "0",
        KeyCode::Num1 => "1",
        KeyCode::Num2 => "2",
        KeyCode::Num3 => "3",
        KeyCode::Num4 => "4",
        KeyCode::Num5 => "5",
        KeyCode::Num6 => "6",
        KeyCode::Num7 => "7",
        KeyCode::Num8 => "8",
        KeyCode::Num9 => "9",
        KeyCode::Subtract => "-",
        KeyCode::EqualSign => "=",
        KeyCode::Add => "+",
        KeyCode::OpenBracket => "[",
        KeyCode::CloseBraket => "]",
        KeyCode::BackSlash => "\\",
        KeyCode::Semicolon => ";",
        KeyCode::GraveAccent => "`",
        KeyCode::SingleQuote => "'",
        KeyCode::Comma => ",",
        KeyCode::Period => ".",
        KeyCode::ForwardSlash => "/",
        KeyCode::Space => " ",
        _ => "unknown",
    }
}

pub fn modifier_state_to_string(modifier_state: ModifiersState) -> String {
    let modifier_str = match modifier_state {
        ModifiersState::SUPER => "command",
        ModifiersState::SHIFT => "shift",
        ModifiersState::CONTROL => "control",
        ModifiersState::ALT => "alt",
        _ => "unknown",
    };
    modifier_str.to_string()
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
