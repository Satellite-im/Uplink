use dioxus::prelude::*;

use kit::{

    elements::{
        button::Button,
        tooltip::{ArrowPosition, Tooltip},
        Appearance,
    },
    icons::{Icon, IconElement},
};

use crate::state::{State, Action};

pub const SCRIPT: &str = include_str!("./script.js");

#[derive(Eq, PartialEq, Props)]
pub struct Props {
    #[props(optional)]
    larger: Option<bool>,
}

#[allow(non_snake_case)]
pub fn PopoutPlayer(cx: Scope<Props>) -> Element {
    let state = use_shared_state::<State>(&cx)?;

    cx.render(rsx! (
        div {
            class: "popout-player",
            div {
                class: "wrap",
                div {
                    class: "loading",
                    IconElement {
                        icon: Icon::Cog6Tooth,
                        size: 40,
                    },
                },
                
                video {
                    src: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4",
                    autoplay: "true",
                    "loop": "true",
                    "muted": "true",
                },
                div {
                    class: "controls",
                    Button {
                        icon: Icon::XMark,
                        appearance: Appearance::Transparent,
                        tooltip: cx.render(rsx!(
                            Tooltip {
                                arrow_position: ArrowPosition::Left,
                                text: String::from("Close")
                            }
                        )),
                        onpress: move |_| {
                            state.write().mutate(Action::TogglePopout);
                        }
                    },
                    Button {
                        icon: Icon::ArrowsPointingOut,
                        appearance: Appearance::Transparent,
                        tooltip: cx.render(rsx!(
                            Tooltip {
                                arrow_position: ArrowPosition::Right,
                                text: String::from("Fullscreen")
                            }
                        )),
                    }
                }
            },
        },
        script { "{SCRIPT}" }
    ))
}
