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

#[derive(Eq, PartialEq, Props)]
pub struct Props {
    in_call_text: String,
    mute_text: String, 
    unmute_text: String,
    listen_text: String,
    silence_text: String,
    end_text: String,
}

#[allow(non_snake_case)]
pub fn RemoteControls(cx: Scope<Props>) -> Element {
    let state: UseSharedState<State> = use_context::<State>(&cx).unwrap();

    cx.render(rsx!(div {
        id: "remote-controls",
        div {
            class: "call-info",
            Label {
                text: cx.props.in_call_text.clone(),
            },
            p {
                "1h 34m",
            }
        },
        div {
            class: "controls",
            Button {
                // TODO: we need to add an icon for this `if state.read().ui.silenced { Icon::Microphone } else { Icon::Microphone }`
                icon: Icon::Microphone,
                appearance: if state.read().ui.muted { Appearance::Danger } else { Appearance::Secondary },
                tooltip: cx.render(rsx!(
                    Tooltip {
                        arrow_position: ArrowPosition::Bottom,
                        text: if state.read().ui.muted { cx.props.unmute_text.clone() } else { cx.props.mute_text.clone() }
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
                        text: if state.read().ui.silenced { cx.props.listen_text.clone() } else { cx.props.silence_text.clone() }
                    }
                )),
                onpress: move |_| {
                    state.write().mutate(Action::ToggleSilence);
                }
            },
            Button {
                icon: Icon::PhoneXMark,
                appearance: Appearance::Danger,
                text: cx.props.end_text.clone(),
                onpress: move |_| {
                    state.write().mutate(Action::EndAll);
                },
            }
        }
    }))
}
