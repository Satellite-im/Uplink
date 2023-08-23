use std::time::Duration;

use chrono::Local;
use dioxus::prelude::*;

use futures::{channel::oneshot, StreamExt};
use kit::elements::{
    button::Button,
    tooltip::{ArrowPosition, Tooltip},
    Appearance,
};

use crate::utils::format_timestamp::format_timestamp_timeago;
use common::state::{Action, State};
use common::{
    icons::outline::Shape as Icon,
    warp_runner::{BlinkCmd, WarpCmd},
    WARP_CMD_CH,
};
use uuid::Uuid;

#[derive(Props)]
pub struct Props<'a> {
    users: Element<'a>,
    call_name: String,
    mute_text: String,
    unmute_text: String,
    listen_text: String,
    silence_text: String,
}

enum CallDialogCmd {
    Hangup(Uuid),
    MuteSelf,
    UnmuteSelf,
}

#[allow(non_snake_case)]
pub fn RemoteControls<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let state = use_shared_state::<State>(cx)?;
    let active_call = state.read().ui.call_info.active_call();
    let active_call_id = active_call.as_ref().map(|x| x.call.id);
    let active_call_answer_time = active_call.as_ref().map(|x| x.answer_time);
    let scope_id = cx.scope_id();
    let update_fn = cx.schedule_update_any();

    use_future(
        cx,
        (&scope_id, &active_call_id, &active_call_answer_time),
        |(scope_id, active_call_id, answer_time)| async move {
            if active_call_id.is_none() {
                return;
            }
            let answer_time = match answer_time {
                Some(r) => r,
                None => return,
            };
            loop {
                let dur_sec = Duration::from_secs(1);
                let dur_min = Duration::from_secs(60);

                let to_sleep = match Local::now().signed_duration_since(answer_time).to_std() {
                    Ok(duration) => {
                        if duration < dur_min {
                            dur_sec
                        } else {
                            dur_min
                        }
                    }
                    Err(_) => dur_sec,
                };

                tokio::time::sleep(to_sleep).await;
                update_fn(scope_id);
            }
        },
    );

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
                            log::error!("failed to send blink command: {e}");
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
                            log::error!("failed to send blink command: {e}");
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
                            log::error!("failed to send blink command: {e}");
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
                    } // TODO: Method to end call before a connection is made
                }
            }
        }
    });

    let active_call = match active_call {
        None => {
            // RemoteControls should only be rendered when there's a call
            return cx.render(rsx!(""));
        }
        Some(c) => c,
    };
    let call = active_call.call;

    cx.render(rsx!(div {
        id: "remote-controls",
        div {
            class: "call-info",
            /*Label {
                text: cx.props.in_call_text.clone(),
            },*/
            cx.props.users.as_ref()
            p {
                class: "call-name",
                "{cx.props.call_name}"
            }
            p {
                class: "call-time",
                format_timestamp_timeago(active_call.answer_time.into(), &state.read().settings.language_id()),
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
                onpress: move |_| {
                    ch.send(CallDialogCmd::Hangup(call.id));
                },
            },
            Button {
                icon: Icon::Cog6Tooth,
                appearance: Appearance::Secondary,
                onpress: move |_| {
                    //TODO
                },
            }

        }
    }))
}
