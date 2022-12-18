use dioxus::prelude::*;
use ui_kit::{
    elements::{
        button::Button,
        tooltip::{ArrowPosition, Tooltip},
        Appearance,
    },
    icons::{Icon, IconElement},
};

use crate::state::{Action, State};

#[allow(non_snake_case)]
pub fn RemoteControls(cx: Scope) -> Element {
    let state: UseSharedState<State> = use_context::<State>(&cx).unwrap();

    cx.render(rsx!(div {
        id: "remote-controls",
        "Remote controls",
        div {
            class: "controls",
            Button {
                icon: Icon::Microphone,
                appearance: Appearance::Transparent,
                tooltip: cx.render(rsx!(
                    Tooltip {
                        arrow_position: ArrowPosition::Bottom,
                        text: String::from("Toggle Mic")
                    }
                )),
            },
            Button {
                icon: Icon::SpeakerWave,
                appearance: Appearance::Transparent,
                tooltip: cx.render(rsx!(
                    Tooltip {
                        arrow_position: ArrowPosition::Bottom,
                        text: String::from("Mute All")
                    }
                )),
            },
            Button {
                icon: Icon::PhoneXMark,
                appearance: Appearance::Danger,
                text: "End".into()
            }
        }
    }))
}
