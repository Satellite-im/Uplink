#[allow(unused_imports)]
use common::icons::outline::Shape as Icon;
use common::language::get_local_text;
use common::state::settings::{GlobalShortcut, Shortcut};
use common::state::Action;
use common::{icons::Icon as IconElement, state::State};
use dioxus::{html::GlobalAttributes, prelude::*};

use dioxus_elements::input_data::keyboard_types::Code;
use dioxus_elements::input_data::keyboard_types::Key;
#[allow(unused_imports)]
use kit::elements::{
    button::Button,
    switch::Switch,
    tooltip::{ArrowPosition, Tooltip},
};
use muda::accelerator::Modifiers;

const AVOID_INPUT_ON_DIV: &str = r#"
    document.getElementById("$UUID").addEventListener("keypress", function (event) {
        event.preventDefault(); 
    });"#;

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

pub fn check_for_conflicts(shortcut: Shortcut, shortcuts: Vec<(GlobalShortcut, Shortcut)>) -> bool {
    let mut instances = 0;

    for sc in shortcuts {
        if sc.1.get_keys_and_modifiers_as_string() == shortcut.get_keys_and_modifiers_as_string() {
            instances += 1;
        }
    }

    instances > 1
}

pub fn KeybindSection(cx: Scope<KeybindSectionProps>) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let keybind_section_id = cx.props.id.clone();
    let is_recording = use_state(cx, || false);
    let update_keybind = use_ref(cx, || None);
    let system_shortcut = Shortcut::get_system_shortcut(state, cx.props.shortcut.clone());
    let new_keybind_has_one_key = use_ref(cx, || false);
    let new_keybind_has_at_least_one_modifier = use_ref(cx, || false);

    if update_keybind.read().is_some() && !is_recording.get() {
        let (keys, modifiers) = update_keybind.read().clone().unwrap();
        state
            .write_silent()
            .settings
            .keybinds
            .retain(|(gs, _)| *gs != cx.props.shortcut);
        state.write().settings.keybinds.push((
            cx.props.shortcut.clone(),
            Shortcut {
                keys: keys,
                modifiers: modifiers,
                system_shortcut: system_shortcut,
            },
        ));
        *update_keybind.write_silent() = None;
    }

    let bindings = cx
        .props
        .bindings
        .iter()
        .find(|(gs, _)| *gs == cx.props.shortcut)
        .map(|(_, sc)| sc.get_keys_and_modifiers_as_string())
        .unwrap_or_default();

    let sc = cx
        .props
        .bindings
        .iter()
        .find(|(gs, _)| *gs == cx.props.shortcut)
        .map(|(_, sc)| sc.clone())
        .unwrap_or_default();

    let recorded_bindings = use_state(cx, || vec![]);

    let eval = use_eval(cx);
    let script = AVOID_INPUT_ON_DIV.replace("$UUID", keybind_section_id.as_str());
    let _ = eval(&script);

    let mut keybind_class = "keybind-section-keys".to_owned();
    if **is_recording {
        keybind_class.push_str(" recording");
    }

    if *is_recording.get() && !state.read().settings.is_recording_new_keybind {
        println!("is_recording_new_keybind: true");
        state.write().settings.is_recording_new_keybind = true;
    }

    if check_for_conflicts(sc, cx.props.bindings.clone()) {
        keybind_class.push_str(" conflicting");
    }
    cx.render(rsx!(
        div {
            id: format_args!("{}", keybind_section_id),
            class: "keybind-section",
            (**is_recording).then(|| rsx!(div {
                class: "keybind-section-mask",
                onclick: move |_| {
                    is_recording.set(false);
                    state.write().settings.is_recording_new_keybind = false;
                }
            })),
            div {
                class: "keybind-section-label",
                "{cx.props.section_label}"
            },
            div {
                class: "{keybind_class}",
                contenteditable: true,
                onfocus: move |_| {
                    is_recording.set(true);
                },
                onkeydown: move |evt| {
                    println!("evt: {:?}", evt); 

                    if evt.data.code() == Code::Escape {
                        is_recording.set(false);
                        evt.stop_propagation();
                        return;
                    }

                    let mut binding = vec![];

                    if is_it_a_key_code(evt.data.key())  {
                        *new_keybind_has_one_key.write_silent() = true;
                        binding.push(evt.data.code().to_string());
                    }

                    let modifier_string_vec = return_string_from_modifier(evt.data.modifiers());
                    if !modifier_string_vec.is_empty() {
                        *new_keybind_has_at_least_one_modifier.write_silent() = true;
                        binding.extend(modifier_string_vec);
                    }

                    recorded_bindings.set(binding);
                    evt.stop_propagation();
                },
                onkeyup: move |_| {
                    if *is_recording.get() && *new_keybind_has_one_key.read() && *new_keybind_has_at_least_one_modifier.read() {
                        let (keys, modifiers) = Shortcut::string_to_keycode_and_modifiers_state(recorded_bindings.get().clone());
                        *update_keybind.write_silent() = Some((keys, modifiers));
                    }
                    *new_keybind_has_one_key.write_silent() = false;
                    *new_keybind_has_at_least_one_modifier.write_silent() = false;
                    is_recording.set(false);
                    state.write().settings.is_recording_new_keybind = false;
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
    if !state.read().settings.pause_global_keybinds {
        state.write().mutate(Action::PauseGlobalKeybinds(true));
    }

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

fn return_string_from_modifier(modifiers: Modifiers) -> Vec<String> {
    let mut modifier_string = vec![];
    for modifier in modifiers.clone() {
        match modifier {
            Modifiers::ALT => modifier_string.push("Alt".to_string()),
            Modifiers::CONTROL => modifier_string.push("Ctrl".to_string()),
            Modifiers::SHIFT => modifier_string.push("Shift".to_string()),
            Modifiers::META => {
                if cfg!(target_os = "macos") {
                    modifier_string.push("Command".to_string())
                } else {
                    modifier_string.push("Windows Key".to_string())
                }
            }
            Modifiers::SUPER => modifier_string.push("Super".to_string()),
            _ => (),
        }
    }
    modifier_string
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
