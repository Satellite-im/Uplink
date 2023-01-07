use dioxus::prelude::*;

use dioxus_desktop::{use_window};
use kit::{
    elements::{
        button::Button,
        tooltip::{ArrowPosition, Tooltip},
        Appearance,
    },
    icons::{Icon, IconElement},
};
pub const SCRIPT: &str = include_str!("./script.js");

#[allow(non_snake_case)]
pub fn PopoutPlayer(cx: Scope) -> Element {
    let window = use_window(cx);

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
                            window.close();
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