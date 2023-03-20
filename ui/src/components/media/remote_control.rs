use dioxus::prelude::*;

use dioxus_desktop::use_window;
use kit::elements::{
    button::Button,
    label::Label,
    tooltip::{ArrowPosition, Tooltip},
    Appearance,
};

use common::icons::outline::Shape as Icon;
use common::state::{Action, State};

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
    let state = use_shared_state::<State>(cx)?;
    let call = state.read().ui.current_call.clone();
    let window = use_window(cx);

    let call = match call {
        None => {
            // RemoteControls should only be rendered when there's a call
            return cx.render(rsx!(""));
        }
        Some(c) => c,
    };

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
                appearance: if call.muted { Appearance::Danger } else { Appearance::Secondary },
                tooltip: cx.render(rsx!(
                    Tooltip {
                        arrow_position: ArrowPosition::Bottom,
                        text: if call.muted { cx.props.unmute_text.clone() } else { cx.props.mute_text.clone() }
                    }
                )),
                onpress: move |_| {
                    state.write().mutate(Action::ToggleMute);
                }
            },
            Button {
                icon: if call.silenced { Icon::SignalSlash } else { Icon::Signal },
                appearance: if call.silenced { Appearance::Danger } else { Appearance::Secondary },
                tooltip: cx.render(rsx!(
                    Tooltip {
                        arrow_position: ArrowPosition::Bottom,
                        text: if call.silenced { cx.props.listen_text.clone() } else { cx.props.silence_text.clone() }
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
                    state.write().mutate(Action::ClearCallPopout(window.clone()));
                    state.write().mutate(Action::DisableMedia);
                },
            }
        }
    }))
}
