#[allow(unused_imports)]
use common::icons::outline::Shape as Icon;
use common::language::get_local_text;
use common::state::settings::{GlobalShortcut, Shortcut};
use common::{icons::Icon as IconElement, state::State};
use dioxus::{html::GlobalAttributes, prelude::*};

use dioxus_elements::input_data::keyboard_types::Key;
#[allow(unused_imports)]
use kit::elements::{
    button::Button,
    switch::Switch,
    tooltip::{ArrowPosition, Tooltip},
};
use muda::accelerator::Modifiers;

#[derive(PartialEq, Props)]
pub struct KeybindProps {
    pub keys: Vec<String>, // TODO: This should be a Vec<Key>
}

#[allow(non_snake_case)]
pub fn Keybind(cx: Scope<KeybindProps>) -> Element {
    let keys_rendered = cx.props.keys.iter().enumerate().map(|(idx, key)| {
        rsx!(div {
            class: "keybind-key",
            div {
                class: "keybind-key-inner",
                "{key.to_uppercase()}",
            }
        },
        if idx != cx.props.keys.len() - 1 {
            rsx!(div {
                class: "keybind-separator",
                IconElement {
                    icon: Icon::Plus
                }
            })
        })
    });

    cx.render(rsx!(keys_rendered))
}

#[derive(PartialEq, Props)]
pub struct KeybindSectionProps {
    pub id: String,
    pub bindings: Vec<(GlobalShortcut, Shortcut)>,
    pub shortcut: GlobalShortcut,
    pub section_label: String,
}

pub fn KeybindSection(cx: Scope<KeybindSectionProps>) -> Element {
    let keybind_section_id = cx.props.id.clone();
    let is_recording = use_state(cx, || false);
    let bindings = cx
        .props
        .bindings
        .iter()
        .find(|(gs, _)| *gs == cx.props.shortcut)
        .map(|(_, sc)| sc.get_keys_and_modifiers_as_string())
        .unwrap_or_default();

    let recorded_bindings = use_state(cx, || vec![]);

    cx.render(rsx!(
        div {
            id: format_args!("{}", keybind_section_id),
            class: "keybind-section",
            (**is_recording).then(|| rsx!(div {
                class: "keybind-section-mask",
                onclick: move |_| {
                    is_recording.set(false);
                }
            })),
            div {
                class: "keybind-section-label",
                "{cx.props.section_label}"
            },
            div {
                class: if **is_recording { "keybind-section-keys recording" } else { "keybind-section-keys" },
                contenteditable: true,
                onfocus: move |_| {
                    is_recording.set(true);
                },
                prevent_default: "oninput",
                onkeydown: move |evt| {
                    println!("evt: {:?}", evt); 
                    let mut binding = vec![];
                    for modifier in evt.data.modifiers().iter() {
                        binding.push(return_string_from_modifier(modifier));
                    }
                    
                    if is_it_a_key_code(evt.data.key()) {
                        binding.push(evt.data.key().to_string());
                    }
                    recorded_bindings.set(binding);
                    evt.stop_propagation();
                },
                onkeyup: move |_| {
                    is_recording.set(false);
                },
                Keybind {
                    keys: if **is_recording { recorded_bindings.get().clone() } else { bindings },
                }
            }
        }
    ))
}

#[allow(non_snake_case)]
pub fn KeybindSettings(cx: Scope) -> Element {
    let state: &UseSharedState<State> = use_shared_state::<State>(cx)?;
    let bindings = state.read().settings.keybinds.clone();

    cx.render(rsx!(
        div {
            id: "settings-keybinds",
            aria_label: "settings-keybinds",
            div {
                class: "settings-keybinds-info",
                IconElement {
                    icon: Icon::Keybind
                },
                p {
                    get_local_text("settings-keybinds.info")
                }
            },
            KeybindSection {
                id: format!("{:?}", GlobalShortcut::IncreaseFontSize),
                section_label: get_local_text("settings-keybinds.increase-font-size"),
                bindings: bindings.clone(),
                shortcut: GlobalShortcut::IncreaseFontSize
            }
            KeybindSection {
                id: format!("{:?}", GlobalShortcut::DecreaseFontSize),
                section_label: get_local_text("settings-keybinds.decrease-font-size"),
                bindings: bindings.clone(),
                shortcut: GlobalShortcut::DecreaseFontSize
            }
            KeybindSection {
                id: format!("{:?}", GlobalShortcut::ToggleMute),
                section_label: get_local_text("settings-keybinds.toggle-mute"),
                bindings: bindings.clone(),
                shortcut: GlobalShortcut::ToggleMute
            }
            KeybindSection {
                id: format!("{:?}", GlobalShortcut::ToggleDeafen),
                section_label: get_local_text("settings-keybinds.toggle-deafen"),
                bindings: bindings.clone(),
                shortcut: GlobalShortcut::ToggleDeafen
            }
        }
    ))
}

fn return_string_from_modifier(modifier: Modifiers) -> String {
    match modifier {
        Modifiers::ALT => "Alt".to_string(),
        Modifiers::CONTROL => "Ctrl".to_string(),
        Modifiers::SHIFT => "Shift".to_string(),
        Modifiers::META => "Meta".to_string(),
        Modifiers::ALT_GRAPH => "AltGr".to_string(),
        Modifiers::CAPS_LOCK => "CapsLock".to_string(),
        Modifiers::FN => "Fn".to_string(),
        Modifiers::FN_LOCK => "FnLock".to_string(),
        Modifiers::NUM_LOCK => "NumLock".to_string(),
        Modifiers::SCROLL_LOCK => "ScrollLock".to_string(),
        Modifiers::SYMBOL => "Symbol".to_string(),
        Modifiers::SYMBOL_LOCK => "SymbolLock".to_string(),
        Modifiers::HYPER => "Hyper".to_string(),
        Modifiers::SUPER => "Super".to_string(),
        _ => "".to_string(),
    }
}

fn is_it_a_key_code(key: Key) -> bool {
    match key {
        Key::Alt => false,
        Key::Control => false,
        Key::Shift => false,
        Key::Meta => false,
        Key::AltGraph => false,
        Key::CapsLock => false,
        Key::Fn => false,
        Key::FnLock => false,
        Key::NumLock => false,
        Key::ScrollLock => false,
        Key::Symbol => false,
        Key::SymbolLock => false,
        Key::Hyper => false,
        Key::Super => false,
        _ => true,
    }
}
