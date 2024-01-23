use dioxus::prelude::*;
use dioxus_desktop::tao::keyboard::ModifiersState;

use super::settings::{GlobalShortcut, Shortcut};

pub fn get_default_keybinds() -> Vec<(GlobalShortcut, Shortcut)> {
    let alt_or_command_modifierstate = if cfg!(target_os = "macos") {
        // SUPER is command on mac
        ModifiersState::SUPER
    } else {
        ModifiersState::ALT
    };
    Vec::from([
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
                vec![alt_or_command_modifierstate, ModifiersState::SHIFT],
                true,
            )),
        ),
        (
            GlobalShortcut::ToggleDeafen,
            Shortcut::from((
                vec![KeyCode::D],
                vec![alt_or_command_modifierstate, ModifiersState::SHIFT],
                true,
            )),
        ),
        (
            GlobalShortcut::OpenDevTools,
            Shortcut::from((
                vec![KeyCode::I],
                vec![ModifiersState::CONTROL, ModifiersState::SHIFT],
                false,
            )),
        ),
        (
            GlobalShortcut::ToggleDevmode,
            Shortcut::from((
                vec![KeyCode::D],
                vec![ModifiersState::CONTROL, ModifiersState::SHIFT],
                false,
            )),
        ),
        (
            GlobalShortcut::SetAppVisible,
            Shortcut::from((
                vec![KeyCode::U],
                vec![ModifiersState::CONTROL, ModifiersState::SHIFT],
                true,
            )),
        ),
        (
            GlobalShortcut::SetAppInvisible,
            Shortcut::from((vec![KeyCode::U], vec![ModifiersState::CONTROL], true)),
        ),
    ])
}

pub fn get_keycode_and_modifier_from_a_shortcut(
    global_shortcut_target: GlobalShortcut,
) -> (Vec<KeyCode>, Vec<ModifiersState>) {
    let mut keycodes = Vec::new();
    let mut modifiers = Vec::new();
    let default_keybinds = get_default_keybinds();
    for (global_shortcut, shortcut) in default_keybinds {
        if global_shortcut.clone() == global_shortcut_target {
            keycodes = shortcut.keys.clone();
            modifiers = shortcut.modifiers.clone();
            break;
        }
    }
    (keycodes, modifiers)
}
