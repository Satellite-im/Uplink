use dioxus::prelude::*;
use futures::{channel::oneshot, StreamExt};
use kit::{
    elements::{
        button::Button,
        tooltip::{ArrowPosition, Tooltip},
        Appearance,
    },
    layout::modal::Modal,
};
use std::rc::Rc;

use crate::{
    components::chat::pinned_messages::PinnedMessages,
    layouts::chats::data::{ChatData, ChatProps},
};

use common::{
    icons::outline::Shape as Icon,
    state::call,
    warp_runner::{BlinkCmd, WarpCmd},
};
use common::{
    state::{Action, State},
    WARP_CMD_CH,
};

use common::language::get_local_text;

use uuid::Uuid;
use warp::{
    blink::{self},
    crypto::DID,
    logging::tracing::log,
    raygun::ConversationType,
};

enum ControlsCmd {
    VoiceCall {
        participants: Vec<DID>,
        conversation_id: Uuid,
    },
}

pub fn get_controls(cx: Scope<ChatProps>) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let data = &cx.props.data;
    let active_chat = data.as_ref().map(|x| &x.active_chat);
    let favorite = data
        .as_ref()
        .map(|d: &Rc<ChatData>| d.is_favorite)
        .unwrap_or_default();
    let conversation_type = if let Some(chat) = active_chat.as_ref() {
        chat.conversation_type
    } else {
        ConversationType::Direct
    };
    let edit_group_activated = cx
        .props
        .show_edit_group
        .get()
        .map(|group_chat_id| active_chat.map_or(false, |chat| group_chat_id == chat.id))
        .unwrap_or(false);
    let show_group_list = cx
        .props
        .show_group_users
        .get()
        .map(|group_chat_id| active_chat.map_or(false, |chat| group_chat_id == chat.id))
        .unwrap_or(false);

    let call_pending = use_state(cx, || false);
    let active_call = state.read().ui.call_info.active_call();
    let call_in_progress = active_call.is_some(); // active_chat.map(|chat| chat.id) == active_call.map(|call| call.conversation_id);

    let show_pinned = use_state(cx, || false);

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<ControlsCmd>| {
        to_owned![call_pending, state];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(cmd) = rx.next().await {
                match cmd {
                    ControlsCmd::VoiceCall {
                        participants,
                        conversation_id,
                    } => {
                        let (tx, rx) = oneshot::channel();
                        if let Err(e) = warp_cmd_tx.send(WarpCmd::Blink(BlinkCmd::OfferCall {
                            conversation_id,
                            participants: participants.clone(),
                            rsp: tx,
                            // todo: make this configurable
                            webrtc_codec: blink::AudioCodec {
                                mime: blink::MimeType::OPUS,
                                sample_rate: blink::AudioSampleRate::High,
                                channels: 1,
                            },
                        })) {
                            log::error!("failed to send command to warp_runner: {e}");
                            call_pending.set(false);
                            continue;
                        }

                        let res = rx.await.expect("warp runner failed");
                        match res {
                            Ok(call_id) => {
                                state.write().mutate(Action::OfferCall(call::Call::new(
                                    call_id,
                                    conversation_id,
                                    participants,
                                )));
                            }
                            Err(e) => {
                                log::error!("BlinkCmd::OfferCall failed: {e}");
                            }
                        }
                        call_pending.set(false);
                    }
                }
            }
        }
    });

    cx.render(rsx!(
        if cx.props.is_owner && conversation_type == ConversationType::Group {
            rsx!(Button {
                icon: Icon::PencilSquare,
                aria_label: "edit-group".into(),
                appearance: if edit_group_activated {
                    Appearance::Primary
                } else {
                    Appearance::Secondary
                },
                tooltip: cx.render(rsx!(Tooltip {
                    arrow_position: ArrowPosition::Top,
                    text: get_local_text("friends.edit-group")
                })),
                onpress: move |_| {
                    if edit_group_activated {
                        cx.props.show_edit_group.set(None);
                    } else if let Some(chat) = active_chat.as_ref() {
                        cx.props.show_edit_group.set(Some(chat.id));
                        cx.props.show_group_users.set(None);
                    }
                }
            })
        }
        if !cx.props.is_owner && conversation_type == ConversationType::Group {
            rsx!(
                Button {
                    icon: Icon::ListBullet,
                    aria_label: "edit-group".into(),
                    appearance: if show_group_list {
                        Appearance::Primary
                    } else {
                        Appearance::Secondary
                    },
                    tooltip: cx.render(rsx!(Tooltip {
                        arrow_position: ArrowPosition::Top,
                        text: get_local_text("friends.view-group")
                    })),
                    onpress: move |_| {
                            if show_group_list {
                                cx.props.show_group_users.set(None);
                            } else if let Some(chat) = active_chat.as_ref() {
                                cx.props.show_group_users.set(Some(chat.id));
                                cx.props.show_edit_group.set(None);

                            }

                    }
                }
            )
        }
        Button {
            icon: if favorite {
                Icon::HeartSlash
            } else {
                Icon::Heart
            },
            disabled: data.is_none(),
            aria_label: get_local_text(if favorite {
                "favorites.remove"
            } else {
                "favorites.favorites"
            }),
            appearance: if favorite {
                Appearance::Primary
            } else {
                Appearance::Secondary
            },
            tooltip: cx.render(rsx!(Tooltip {
                arrow_position: ArrowPosition::Top,
                text: if favorite {
                    get_local_text("favorites.remove")
                } else {
                    get_local_text("favorites.add")
                }
            })),
            onpress: move |_| {
                if let Some(chat) = active_chat.as_ref() {
                    state.write().mutate(Action::ToggleFavorite(&chat.id));
                }
            }
        },
        show_pinned.then(|| rsx!(
            Modal {
                open: true,
                transparent: true,
                with_title: get_local_text("messages.pin-view"),
                onclose: move |_| {
                    show_pinned.set(false);
                },
                if let Some(chat) = active_chat {
                    rsx!(PinnedMessages{ active_chat: chat.clone(), onclose: move |_| {
                        show_pinned.set(false);
                    } })
                }
            }
        )),
        Button {
            icon: Icon::Pin,
            aria_label: "pin-label".into(),
            appearance: if *show_pinned.clone() { Appearance::Primary } else { Appearance::Secondary },
            tooltip: cx.render(rsx!(Tooltip {
                arrow_position: ArrowPosition::Top,
                text: get_local_text("messages.pin-view"),
            })),
            onpress: move |_| {
                show_pinned.set(true);
            }
        }
        Button {
            icon: Icon::PhoneArrowUpRight,
            disabled: !state.read().configuration.developer.experimental_features || *call_pending.current() || call_in_progress,
            aria_label: "Call".into(),
            appearance: Appearance::Secondary,
            tooltip: cx.render(rsx!(Tooltip {
                arrow_position: ArrowPosition::Top,
                text: if !state.read().configuration.developer.experimental_features { get_local_text("uplink.coming-soon") } else { get_local_text("uplink.call") }
            })),
            onpress: move |_| {
                if let Some(chat) = active_chat.as_ref() {
                    ch.send(ControlsCmd::VoiceCall{
                        participants: chat.participants.iter().cloned().collect(),
                        conversation_id: chat.id
                    });
                    call_pending.set(true);
                }
            }
        },
        Button {
            icon: Icon::VideoCamera,
            disabled: true,
            aria_label: "Videocall".into(),
            appearance: Appearance::Secondary,
            tooltip: cx.render(rsx!(Tooltip {
                arrow_position: ArrowPosition::TopRight,
                text: get_local_text("uplink.coming-soon"),
            })),
        },
    ))
}
