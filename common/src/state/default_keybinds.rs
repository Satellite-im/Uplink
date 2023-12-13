use dioxus::prelude::*;
use dioxus_desktop::tao::keyboard::ModifiersState;

use super::settings::{GlobalShortcut, Shortcut};

pub fn get_default_keybinds() -> Vec<(GlobalShortcut, Shortcut)> {
    let alt_or_command = if cfg!(target_os = "macos") {
        // SUPER is command on mac
        ModifiersState::SUPER
    } else {
        ModifiersState::ALT
    };
    Vec::from([
        // To avoid multi-key conflicts, when using a shortcut that uses multiple `KeyCode` values, it's best to use the `ALT` modifier by default.
        (
            GlobalShortcut::IncreaseFontSize,
            Shortcut::from((
                // TODO(KeyCode::Add):We need to treat this carefully, keyboard doesn't identify Add as + properly
                // And as EqualSign, not works + from Numpad
                vec![KeyCode::EqualSign],
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
                vec![alt_or_command, ModifiersState::SHIFT],
                true,
            )),
        ),
        (
            GlobalShortcut::ToggleDeafen,
            Shortcut::from((
                vec![KeyCode::D],
                vec![alt_or_command, ModifiersState::SHIFT],
                true,
            )),
        ),
    ])
}
