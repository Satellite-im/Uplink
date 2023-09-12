use std::time::Duration;

use chrono::Local;
use dioxus::prelude::*;

use futures::{channel::oneshot, StreamExt};
use kit::{
    components::{user_image::UserImage, user_image_group::UserImageGroup},
    elements::{
        button::Button,
        label::Label,
        tooltip::{ArrowPosition, Tooltip},
        Appearance,
    },
    User,
};

use crate::utils::{
    build_participants, build_user_from_identity, format_timestamp::format_timestamp_timeago,
};
use common::{
    icons::outline::Shape as Icon,
    state::{
        call::{ActiveCall, Call},
        ui::Layout,
    },
    warp_runner::{BlinkCmd, WarpCmd},
    WARP_CMD_CH,
};
use common::{
    language::get_local_text,
    state::{Action, State},
};
use uuid::Uuid;

enum CallDialogCmd {
    Hangup(Uuid),
    MuteSelf,
    UnmuteSelf,
}

enum PendingCallDialogCmd {
    Accept(Uuid),
    Reject(Uuid),
}

#[derive(PartialEq, Eq, Props)]
pub struct Props {
    in_chat: bool,
}

#[allow(non_snake_case)]
pub fn CallControl(cx: Scope<Props>) -> Element {
    let state = use_shared_state::<State>(cx)?;
    match state.read().ui.call_info.active_call() {
        Some(call) => cx.render(rsx!(ActiveCallControl {
            active_call: call,
            in_chat: cx.props.in_chat,
            mute_text: get_local_text("remote-controls.mute"),
            unmute_text: get_local_text("remote-controls.unmute"),
            listen_text: get_local_text("remote-controls.listen"),
            silence_text: get_local_text("remote-controls.silence"),
        })),
        None => match state.read().ui.call_info.pending_calls().first() {
            Some(call) => cx.render(rsx!(PendingCallDialog {
                call: call.clone(),
                in_chat: cx.props.in_chat,
            })),
            None => cx.render(rsx!(())),
        },
    }
}

#[derive(PartialEq, Eq, Props)]
pub struct ActiveCallProps {
    active_call: ActiveCall,
    in_chat: bool,
    mute_text: String,
    unmute_text: String,
    listen_text: String,
    silence_text: String,
}

#[allow(non_snake_case)]
fn ActiveCallControl(cx: Scope<ActiveCallProps>) -> Element {
    log::trace!("Rendering active call window");
    let state = use_shared_state::<State>(cx)?;
    let active_call = &cx.props.active_call;
    let active_call_id = active_call.call.id;
    let active_call_answer_time = active_call.answer_time;
    let scope_id = cx.scope_id();
    let outgoing = active_call.call.participants_joined.is_empty();
    let update_fn = cx.schedule_update_any();

    use_future(
        cx,
        (&scope_id, &active_call_id, &active_call_answer_time),
        |(scope_id, _, answer_time)| async move {
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
    if state.read().ui.current_layout == Layout::Compose {
        match state.read().get_active_chat() {
            None => {
                if cx.props.in_chat {
                    return cx.render(rsx!(()));
                }
            }
            Some(c) => {
                if active_call.call.conversation_id.eq(&c.id) != cx.props.in_chat {
                    return cx.render(rsx!(()));
                }
            }
        };
    }
    let call = &active_call.call;

    let participants = state.read().get_identities(&call.participants);
    let other_participants = state.read().remove_self(&participants);
    let participants_name = State::join_usernames(&other_participants);

    cx.render(rsx!(div {
        id: "remote-controls",
        class: format_args!("{}", if cx.props.in_chat {"in-chat"} else {""}),
        div {
            class: format_args!("call-label {}", if cx.props.in_chat {"in-chat"} else {""}),
            outgoing.then(|| rsx!(Label {
                text: get_local_text("remote-controls.outgoing-call"),
            }))
        }
        div {
            class: "call-info",
            div {
                class: format_args!("calling {}", if cx.props.in_chat {"in-chat"} else {""}),
                div {
                    class: format_args!("user-group-scale {}", if cx.props.in_chat {"in-chat"} else {""}),
                    if other_participants.is_empty() {
                        rsx!(div {
                            class: "lonely-call",
                            get_local_text("remote-controls.empty")
                        })
                    } else if cx.props.in_chat {
                        let call_participants: Vec<_> = other_participants
                            .iter()
                            .map(|x| (call.participants_speaking.contains_key(&x.did_key()), build_user_from_identity(x)))
                            .collect();
                        rsx!(CallUserImageGroup {
                            participants: call_participants,
                        })
                    } else  {
                        rsx!(UserImageGroup {
                            participants: build_participants(&other_participants),
                        })
                    }
                    
                }
            }
            (!cx.props.in_chat).then(||rsx!(
                p {
                    class: "call-name",
                    "{participants_name}"
                }
            )),
            p {
                class: format_args!("call-time {}", if cx.props.in_chat {"in-chat"} else {""}),
                format_timestamp_timeago(active_call.answer_time.into(), &state.read().settings.language_id()),
            }
        },
        div {
            class: "controls",
            Button {
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
            //Currently not impl
            /*Button {
                icon: Icon::Cog6Tooth,
                appearance: Appearance::Secondary,
                onpress: move |_| {
                    //TODO
                },
            }*/

        }
    }))
}

#[derive(PartialEq, Eq, Props)]
pub struct PendingCallProps {
    call: Call,
    in_chat: bool,
}

#[allow(non_snake_case)]
fn PendingCallDialog(cx: Scope<PendingCallProps>) -> Element {
    log::trace!("Rendering pending call window");
    let state = use_shared_state::<State>(cx)?;
    let ch = use_coroutine(cx, |mut rx| {
        to_owned![state];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(cmd) = rx.next().await {
                match cmd {
                    PendingCallDialogCmd::Accept(id) => {
                        let (tx, rx) = oneshot::channel();
                        if let Err(_e) = warp_cmd_tx.send(WarpCmd::Blink(BlinkCmd::AnswerCall {
                            call_id: id,
                            rsp: tx,
                        })) {
                            log::error!("failed to send blink command");
                            continue;
                        }

                        match rx.await {
                            Ok(_) => {
                                state.write().mutate(Action::AnswerCall(id));
                            }
                            Err(e) => {
                                log::error!("warp_runner failed to answer call: {e}");
                            }
                        }
                    }
                    PendingCallDialogCmd::Reject(id) => {
                        let (tx, rx) = oneshot::channel();
                        if let Err(_e) = warp_cmd_tx.send(WarpCmd::Blink(BlinkCmd::RejectCall {
                            call_id: id,
                            rsp: tx,
                        })) {
                            log::error!("failed to send blink command");
                            continue;
                        }

                        match rx.await {
                            Ok(_) => {
                                state.write().ui.call_info.reject_call(id);
                            }
                            Err(e) => {
                                log::error!("warp_runner failed to answer call: {e}");
                            }
                        }
                    }
                }
            }
        }
    });

    let call = &cx.props.call;
    if state.read().ui.current_layout == Layout::Compose {
        match state.read().get_active_chat() {
            None => {
                if cx.props.in_chat {
                    return cx.render(rsx!(()));
                }
            }
            Some(c) => {
                if call.conversation_id.eq(&c.id) != cx.props.in_chat {
                    return cx.render(rsx!(()));
                }
            }
        };
    }
    let mut participants = state.read().get_identities(&call.participants);
    participants = state.read().remove_self(&participants);
    let usernames = match state.read().get_chat_by_id(call.id) {
        Some(c) => match c.conversation_name {
            Some(name) => name,
            None => State::join_usernames(&participants),
        },
        None => State::join_usernames(&participants),
    };

    cx.render(rsx!(CallDialog {
        caller: cx.render(rsx!(UserImageGroup {
            participants: build_participants(&participants),
        },)),
        in_chat: cx.props.in_chat,
        usernames: usernames,
        icon: Icon::PhoneArrowDownLeft,
        description: get_local_text("remote-controls.incoming-call"),
        with_accept_btn: cx.render(rsx!(Button {
            icon: Icon::Phone,
            appearance: Appearance::Success,
            onpress: move |_| {
                ch.send(PendingCallDialogCmd::Accept(call.id));
            }
        })),
        with_deny_btn: cx.render(rsx!(Button {
            icon: Icon::PhoneXMark,
            appearance: Appearance::Danger,
            onpress: move |_| {
                ch.send(PendingCallDialogCmd::Reject(call.id));
            }
        })),
    }))
}

#[derive(Props)]
pub struct CallDialogProps<'a> {
    caller: Element<'a>,
    icon: Icon,
    description: String,
    usernames: String,
    in_chat: bool,
    #[props(optional)]
    with_accept_btn: Option<Element<'a>>,
    #[props(optional)]
    with_deny_btn: Option<Element<'a>>,
}

// todo: remove this
#[allow(unused)]
#[allow(non_snake_case)]
pub fn CallDialog<'a>(cx: Scope<'a, CallDialogProps<'a>>) -> Element<'a> {
    let with_accept_btn = match cx.props.with_accept_btn.clone() {
        Some(w_a_b) => w_a_b,
        None => None,
    };
    let with_deny_btn = match cx.props.with_deny_btn.clone() {
        Some(w_d_b) => w_d_b,
        None => None,
    };
    cx.render(rsx! (
        div {
            class:format_args!("call-dialog {}", if cx.props.in_chat {"in-chat"} else {""}),
            div {
                class: "call-information",
                rsx!(
                    common::icons::Icon {
                        ..common::icons::IconProps {
                            class: None,
                            size: 20,
                            fill:"currentColor",
                            icon: cx.props.icon,
                            disabled: false,
                            disabled_fill: "#9CA3AF"
                        },
                    },
                )
                p {
                    "{cx.props.description}",
                }
            },
            div {
                class: "calling",
                div {
                    class: "user-group-scale",
                    &cx.props.caller,
                }
            },
            (!cx.props.in_chat).then(||rsx!(div {
                class: "users",
                "{cx.props.usernames}",
            }))
            div {
                class: "controls",
                with_accept_btn,
                with_deny_btn,
            }
        }
    ))
}

#[derive(Props, PartialEq)]
pub struct CallUserImageProps {
    participants: Vec<(bool, User)>,
}

#[allow(non_snake_case)]
pub fn CallUserImageGroup(cx: Scope<CallUserImageProps>) -> Element {
    cx.render(rsx!(cx.props.participants.iter().map(
        |(speaking, user)| {
            rsx!(div {
                class: format_args!("call-user {}", if *speaking {"speaking"} else {""}),
                UserImage {
                    platform: user.platform,
                    image: user.photo.clone(),
                }
            })
        }
    )))
}
