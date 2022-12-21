use dioxus::prelude::*;
use kit::{
    elements::{
        button::Button,
        label::Label,
        tooltip::{ArrowPosition, Tooltip},
        Appearance,
    },
    icons::Icon,
};

use crate::state::{Action, State};

#[allow(non_snake_case)]
pub fn RemoteControls(cx: Scope) -> Element {
    let state: UseSharedState<State> = use_context::<State>(&cx).unwrap();

    cx.render(rsx!(div {
        id: "remote-controls",
        div {
            class: "call-info",
            Label {
                text: "In Call".into(),
            },
            p {
                "1h 34m",
            }
        },
        div {
            class: "controls",
            Button {
                // TODO: we need to add an icon for this
                icon: if state.read().ui.silenced { Icon::Microphone } else { Icon::Microphone },
                appearance: if state.read().ui.muted { Appearance::Danger } else { Appearance::Secondary },
                tooltip: cx.render(rsx!(
                    Tooltip {
                        arrow_position: ArrowPosition::Bottom,
                        text: if state.read().ui.muted { String::from("Unmute") } else { String::from("Mute") }
                    }
                )),
                onpress: move |_| {
                    state.write().mutate(Action::ToggleMute);
                }
            },
            Button {
                icon: if state.read().ui.silenced { Icon::SignalSlash } else { Icon::Signal },
                appearance: if state.read().ui.silenced { Appearance::Danger } else { Appearance::Secondary },
                tooltip: cx.render(rsx!(
                    Tooltip {
                        arrow_position: ArrowPosition::Bottom,
                        text: if state.read().ui.silenced { String::from("Listen") } else { String::from("Silence") }
                    }
                )),
                onpress: move |_| {
                    state.write().mutate(Action::ToggleSilence);
                }
            },
            Button {
                icon: Icon::PhoneXMark,
                appearance: Appearance::Danger,
                text: "End".into(),
                onpress: move |_| {
                    state.write().mutate(Action::EndAll);
                },
            }
        }
    }))
}
