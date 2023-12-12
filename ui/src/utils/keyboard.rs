use std::collections::HashMap;

use dioxus::prelude::{KeyCode, Props};
use dioxus_core::prelude::*;
use dioxus_desktop::use_global_shortcut;
use dioxus_desktop::wry::application::keyboard::ModifiersState;
use dioxus_html::g;

#[derive(Eq, PartialEq, Hash, Debug)]
pub enum GlobalShortcut {
    ToggleMute,
    ToggleDeafen,
    IncreaseFontSize,
    DecreaseFontSize,
}

#[derive(Eq, PartialEq, Debug)]
pub struct Shortcut {
    keys: Vec<KeyCode>,             // Keys required
    modifiers: Vec<ModifiersState>, // Modifier keys required
    system_shortcut: bool, // Determines if the shortcut should work system-wide i.e. even when uplink is not in focus
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

#[derive(Props)]
pub struct Props<'a> {
    on_global_shortcut: EventHandler<'a, GlobalShortcut>,
    // TODO: overrides: Vec<(String, String)> allow for overriding the default bindings
}

pub fn get_default_keybinds() -> HashMap<GlobalShortcut, Shortcut> {
    HashMap::from([
        // To avoid multi-key conflicts, when using a shortcut that uses multiple `KeyCode` values, it's best to use the `ALT` modifier by default.
        (
            GlobalShortcut::IncreaseFontSize,
            Shortcut::from((
                vec![KeyCode::Add],
                vec![ModifiersState::CONTROL, ModifiersState::SHIFT],
                false,
            )),
        ),
        (
            GlobalShortcut::DecreaseFontSize,
            Shortcut::from((
                vec![KeyCode::Subtract],
                vec![ModifiersState::CONTROL, ModifiersState::SHIFT],
                false,
            )),
        ),
        (
            GlobalShortcut::ToggleMute,
            Shortcut::from((
                vec![KeyCode::M],
                vec![ModifiersState::ALT, ModifiersState::SHIFT],
                true,
            )),
        ),
        (
            GlobalShortcut::ToggleDeafen,
            Shortcut::from((
                vec![KeyCode::D],
                vec![ModifiersState::ALT, ModifiersState::SHIFT],
                true,
            )),
        ),
    ])
}

#[allow(non_snake_case)]
pub fn KeyboardShortcut<'a>(cx: Scope<'a, Props>) -> Element<'a> {
    if cfg!(target_os = "linux") {
        return None;
    }

    let keybinds = get_default_keybinds();

    for (global_shortcut, shortcut) in keybinds {
        use_global_shortcut(cx, (shortcut.keys, shortcut.modifiers), move || {
            // TODO: Call on_command event handler and pass the called global shortcut: cx.props.on_command.call(GlobalShortcut::IncreaseFontSize);
            println!("Global action fired: {:?}", global_shortcut);
            cx.props.on_global_shortcut.call(global_shortcut);
        });
    }

    None
}
