use dioxus::prelude::*;

use kit::{
    elements::{
        button::Button,
        tooltip::{ArrowPosition, Tooltip},
        Appearance,
    },
    icons::{Icon, IconElement},
};

use crate::{window_manager::WindowManagerCmd, WINDOW_CMD_CH};

use super::player::WindowDropHandler;
pub const SCRIPT: &str = include_str!("./script.js");

#[inline_props]
#[allow(non_snake_case)]
pub fn PopoutPlayer(cx: Scope, _drop_handler: WindowDropHandler) -> Element {
    let cmd_tx = WINDOW_CMD_CH.tx.clone();

    cx.render(
        rsx! (
        div {
            id: "video-poped-out",
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
                    "loop": "false",
                    muted: "false"
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
                            if let Err(_e) = cmd_tx.send(WindowManagerCmd::ClosePopout) {
                                //todo: log error
                            }
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
