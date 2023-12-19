#[allow(unused_imports)]
use common::icons::outline::Shape as Icon;
use common::language::get_local_text;
use common::state::settings::{GlobalShortcut, Shortcut};
use common::{icons::Icon as IconElement, state::State};
use dioxus::{html::GlobalAttributes, prelude::*};

use kit::elements::Appearance;
#[allow(unused_imports)]
use kit::elements::{
    button::Button,
    switch::Switch,
    tooltip::{ArrowPosition, Tooltip},
};

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
    pub bindings: Vec<(GlobalShortcut, Shortcut)>,
    pub shortcut: GlobalShortcut,
    pub section_label: String,
}

pub fn KeybindSection(cx: Scope<KeybindSectionProps>) -> Element {
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
                    // let mut binding = vec![];
                    // for modifier in evt.data.modifiers().iter() {
                    //     binding.push(modifier.to_string());
                    // }
                    // binding.push(evt.data.code().to_string());

                    // recorded_bindings.set(binding);
                    evt.stop_propagation();
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
                    "Keyboard shortcuts are paused while you're on this page."
                }
            },
            KeybindSection {
                section_label: get_local_text("settings-keybinds.increase-font-size"),
                bindings: bindings.clone(),
                shortcut: GlobalShortcut::IncreaseFontSize
            }
            KeybindSection {
                section_label: get_local_text("settings-keybinds.decrease-font-size"),
                bindings: bindings.clone(),
                shortcut: GlobalShortcut::DecreaseFontSize
            }
            KeybindSection {
                section_label: get_local_text("settings-keybinds.toggle-mute"),
                bindings: bindings.clone(),
                shortcut: GlobalShortcut::ToggleMute
            }
            KeybindSection {
                section_label: get_local_text("settings-keybinds.toggle-deafen"),
                bindings: bindings.clone(),
                shortcut: GlobalShortcut::ToggleDeafen
            }
        }
    ))
}
