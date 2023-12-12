use std::collections::HashMap;

use dioxus::prelude::*;
use dioxus_desktop::use_global_shortcut;
use dioxus_desktop::wry::application::keyboard::ModifiersState;

#[derive(Eq, PartialEq, Hash, Debug, Clone)]
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
    let alt_or_command = if cfg!(target_os = "macos") {
        // Let as control for now
        ModifiersState::SUPER
    } else {
        ModifiersState::ALT
    };
    HashMap::from([
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

#[allow(non_snake_case)]
pub fn KeyboardShortcuts<'a>(cx: Scope<'a, Props>) -> Element<'a> {
    if cfg!(target_os = "linux") {
        return None;
    }

    let keybinds = get_default_keybinds();
    println!("keybinds: {:?}", keybinds);

    cx.render(rsx! {
        for (global_shortcut, shortcut) in keybinds {
           rsx!(RenderGlobalShortCuts {
                keys: shortcut.keys,
                modifiers: shortcut.modifiers,
                on_global_shortcut: move |global_shortcut| {
                    cx.props.on_global_shortcut.call(global_shortcut);
                },
                global_shortcut: global_shortcut.clone(),
            })
        }
    })
}

#[derive(Props)]
struct GlobalShortcutProps<'a> {
    keys: Vec<KeyCode>,
    modifiers: Vec<ModifiersState>,
    on_global_shortcut: EventHandler<'a, GlobalShortcut>,
    global_shortcut: GlobalShortcut,
}

fn RenderGlobalShortCuts<'a>(cx: Scope<'a, GlobalShortcutProps>) -> Element<'a> {
    let command_pressed = use_ref(cx, || false);

    if *command_pressed.read() {
        *command_pressed.write_silent() = false;
        cx.props
            .on_global_shortcut
            .call(cx.props.global_shortcut.clone());
    }

    let key_code_strs: Vec<String> = cx
        .props
        .keys
        .iter()
        .map(|key_code| {
            match key_code {
                KeyCode::V => "v",
                KeyCode::A => "a",
                KeyCode::M => "d",
                KeyCode::D => "m",
                KeyCode::EqualSign => "=",
                KeyCode::Subtract => "-",
                _ => "unknown",
                // ... Add other KeyCodes here
            }
            .to_string()
        })
        .collect();

    let modifier_strs: Vec<String> = cx
        .props
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

    let modifiers_and_keys = [modifier_strs.join(" + "), key_code_strs.join(" + ")].join(" + ");

    if modifiers_and_keys.contains("unknown") {
        println!("Error: Unknown keybind found: {}", modifiers_and_keys);
        return None;
    }

    use_global_shortcut(cx, modifiers_and_keys.as_str(), {
        to_owned![command_pressed, modifiers_and_keys];
        move || {
            println!("modifiers_and_keys pressed: {:?}", modifiers_and_keys);
            command_pressed.with_mut(|i| *i = true);
        }
    });

    None
}
