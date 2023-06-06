use dioxus::prelude::*;

use dioxus_desktop::use_window;
use futures::{channel::oneshot, StreamExt};
use kit::elements::{
    button::Button,
    label::Label,
    tooltip::{ArrowPosition, Tooltip},
    Appearance,
};

use common::state::{Action, State};
use common::{
    icons::outline::Shape as Icon,
    warp_runner::{BlinkCmd, WarpCmd},
    WARP_CMD_CH,
};
use uuid::Uuid;

#[derive(Eq, PartialEq, Props)]
pub struct Props {
    in_call_text: String,
    mute_text: String,
    unmute_text: String,
    listen_text: String,
    silence_text: String,
    end_text: String,
}

enum CallDialogCmd {
    Hangup(Uuid),
    MuteSelf,
    UnmuteSelf,
}

#[allow(non_snake_case)]
pub fn RemoteControls(cx: Scope<Props>) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let call = state.read().ui.call_info.active_call();
    let window = use_window(cx);

    let ch: &Coroutine<CallDialogCmd> = use_coroutine(cx, |mut rx| {
        to_owned![state];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(cmd) = rx.next().await {
                match cmd {
                    CallDialogCmd::Hangup(_id) => {
                        let (tx, rx) = oneshot::channel();
                        if let Err(e) =
                            warp_cmd_tx.send(WarpCmd::Blink(BlinkCmd::LeaveCall { rsp: tx }))
                        {
                            log::error!("failed to send blink command");
                            continue;
                        }

                        match rx.await {
                            Ok(_) => {
                                state.write().mutate(Action::EndCall);
                            }
                            Err(e) => {
                                log::error!("warp_runner failed to answer call: {e}");
                            }
                        }
                    }
                    CallDialogCmd::MuteSelf => {
                        let (tx, rx) = oneshot::channel();
                        if let Err(e) =
                            warp_cmd_tx.send(WarpCmd::Blink(BlinkCmd::MuteSelf { rsp: tx }))
                        {
                            log::error!("failed to send blink command");
                            continue;
                        }

                        match rx.await {
                            Ok(_) => {
                                // disaster waiting to happen if State ever gets out of sync with blink.
                                state.write().mutate(Action::ToggleMute);
                            }
                            Err(e) => {
                                log::error!("warp_runner failed to mute self: {e}");
                            }
                        }
                    }
                    CallDialogCmd::UnmuteSelf => {
                        let (tx, rx) = oneshot::channel();
                        if let Err(e) =
                            warp_cmd_tx.send(WarpCmd::Blink(BlinkCmd::UnmuteSelf { rsp: tx }))
                        {
                            log::error!("failed to send blink command");
                            continue;
                        }

                        match rx.await {
                            Ok(_) => {
                                // disaster waiting to happen if State ever gets out of sync with blink.
                                state.write().mutate(Action::ToggleMute);
                            }
                            Err(e) => {
                                log::error!("warp_runner failed to unmute self: {e}");
                            }
                        }
                    }
                }
            }
        }
    });

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
                appearance: if call.self_muted { Appearance::Danger } else { Appearance::Secondary },
                tooltip: cx.render(rsx!(
                    Tooltip {
                        arrow_position: ArrowPosition::Bottom,
                        text: if call.self_muted { cx.props.unmute_text.clone() } else { cx.props.mute_text.clone() }
                    }
                )),
                onpress: move |_| {
                    if call.self_muted { ch.send(CallDialogCmd::UnmuteSelf); } else { ch.send(CallDialogCmd::MuteSelf); }
                }
            },
            Button {
                icon: if call.call_silenced { Icon::SignalSlash } else { Icon::Signal },
                appearance: if call.call_silenced { Appearance::Danger } else { Appearance::Secondary },
                tooltip: cx.render(rsx!(
                    Tooltip {
                        arrow_position: ArrowPosition::Bottom,
                        text: if call.call_silenced { cx.props.listen_text.clone() } else { cx.props.silence_text.clone() }
                    }
                )),
                onpress: move |_| {
                    // todo: send command
                }
            },
            Button {
                icon: Icon::PhoneXMark,
                appearance: Appearance::Danger,
                text: cx.props.end_text.clone(),
                onpress: move |_| {
                    ch.send(CallDialogCmd::Hangup(call.id));
                },
            }
        }
    }))
}
