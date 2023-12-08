#[allow(unused_imports)]
use common::icons::outline::Shape as Icon;
use common::icons::Icon as IconElement;
use common::language::get_local_text;
use dioxus::prelude::*;

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
                "{key}",
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
    pub keys: Vec<String>, // TODO: This should be a Vec<Key>
    pub section_label: String,
}

pub fn KeybindSection(cx: Scope<KeybindSectionProps>) -> Element {
    cx.render(rsx!(
        div {
            class: "keybind-section",
            div {
                class: "keybind-section-label",
                "{cx.props.section_label}"
            },
            div {
                class: "keybind-section-keys",
                Keybind {
                    keys: cx.props.keys.clone()
                }
            },
            div {
                class: "keybind-section-description",
                Button {
                    icon: Icon::Keybind,
                    disabled: true,
                    appearance: Appearance::Secondary,
                    onpress: |_| {},
                    tooltip: cx.render(rsx!(
                        Tooltip {
                            arrow_position: ArrowPosition::Right,
                            text: get_local_text("settings-keybinds.change-keybind")
                        }
                    )),
                }
            }
        }
    ))
}

#[allow(non_snake_case)]
pub fn KeybindSettings(cx: Scope) -> Element {
    cx.render(rsx!(
        div {
            id: "settings-keybinds",
            aria_label: "settings-keybinds",
            KeybindSection {
                section_label: get_local_text("settings-keybinds.increase-font-size"),
                keys: vec!["Ctrl".into(), "Shift".into(), "+".into()]
            },
            KeybindSection {
                section_label: get_local_text("settings-keybinds.decrease-font-size"),
                keys: vec!["Ctrl".into(), "Shift".into(), "-".into()]
            }
        }
    ))
}
