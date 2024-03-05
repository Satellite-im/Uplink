use dioxus::prelude::*;
use futures::{channel::oneshot, StreamExt};
use kit::{
    components::invisible_closer::InvisibleCloser,
    elements::{
        button::Button,
        tooltip::{ArrowPosition, Tooltip},
        Appearance,
    },
    layout::modal::Modal,
};

use super::pinned_messages::PinnedMessages;
use crate::layouts::chats::data::{ChatData, ChatProps};

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
use warp::{crypto::DID, raygun::ConversationSettings};

use tracing::log;

enum ControlsCmd {
    VoiceCall {
        participants: Vec<DID>,
        conversation_id: Uuid,
    },
}

pub fn get_controls(cx: Scope<ChatProps>) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let minimal = state.read().ui.metadata.minimal_view;
    let chat_data = use_shared_state::<ChatData>(cx)?;
    let favorite = chat_data.read().active_chat.is_favorite();

    let call_pending = use_state(cx, || false);
    let show_more = use_state(cx, || false);
    let active_call = state.read().ui.call_info.active_call();
    let call_in_progress = active_call.is_some(); // active_chat.map(|chat| chat.id) == active_call.map(|call| call.conversation_id);

    let show_pinned = use_state(cx, || false);

    use_effect(cx, &minimal, |_| {
        to_owned![show_more];
        async move {
            if *show_more.get() {
                show_more.set(false);
            }
        }
    });
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

    let (arrow_top, arrow_top_right) = if minimal {
        (ArrowPosition::Right, ArrowPosition::Right)
    } else {
        (ArrowPosition::Top, ArrowPosition::TopRight)
    };

    let (text_builder, tooltip_builder) = (
        |txt| {
            if minimal {
                get_local_text(txt)
            } else {
                String::new()
            }
        },
        |txt, arrow| {
            if minimal {
                cx.render(rsx!(()))
            } else {
                cx.render(rsx!(Tooltip {
                    arrow_position: arrow,
                    text: get_local_text(txt)
                }))
            }
        },
    );

    let show_edit_members = || match chat_data.read().active_chat.conversation_settings() {
        ConversationSettings::Group(group_settings) => {
            cx.props.is_owner || group_settings.members_can_add_participants()
        }
        ConversationSettings::Direct(_) => false,
    };
    let show_group_settings = || match chat_data.read().active_chat.conversation_settings() {
        ConversationSettings::Group(_) => cx.props.is_owner,
        ConversationSettings::Direct(_) => false,
    };
    let buttons = cx.render(rsx!(
        if show_edit_members() {
            rsx!(Button {
                icon: Icon::Users,
                aria_label: "edit-group-members".into(),
                appearance: if cx.props.show_manage_members.is_some() {
                    Appearance::Primary
                } else {
                    Appearance::Secondary
                },
                text: text_builder("friends.manage-group-members"),
                tooltip: tooltip_builder("friends.manage-group-members", arrow_top),
                onpress: move |_| {
                    let active = &chat_data.read().active_chat;
                    if cx.props.show_manage_members.is_some() {
                        cx.props.show_manage_members.set(None);
                    } else if active.is_initialized {
                        cx.props.show_manage_members.set(Some(active.id()));
                        cx.props.show_group_users.set(None);
                        cx.props.show_group_settings.set(false);
                    }
                    show_more.set(false);
                }
            })
        }
        if show_group_settings() {
            rsx!(Button {
                icon: Icon::Cog,
                aria_label: "group-settings".into(),
                appearance: Appearance::Secondary,
                text: text_builder("settings"),
                tooltip: tooltip_builder("settings", arrow_top),
                onpress: move |_| {
                    if *cx.props.show_group_settings.get() {
                        cx.props.show_group_settings.set(false);
                    } else if chat_data.read().active_chat.is_initialized {
                        cx.props.show_group_settings.set(true);
                        cx.props.show_manage_members.set(None);
                        cx.props.show_group_users.set(None);
                    }
                }
            })
        }
        Button {
            icon: if favorite {
                Icon::HeartSlash
            } else {
                Icon::Heart
            },
            disabled: !chat_data.read().active_chat.is_initialized,
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
            text: text_builder(if favorite {
                "favorites.remove"
            } else {
                "favorites.add"
            }),
            tooltip: tooltip_builder(if favorite {
                "favorites.remove"
            } else {
                "favorites.add"
            }, arrow_top),
            onpress: move |_| {
                if chat_data.read().active_chat.is_initialized {
                    state.write().mutate(Action::ToggleFavorite(&chat_data.read().active_chat.id()));
                }
            }
        },
        Button {
            icon: Icon::Pin,
            aria_label: "pin-label".into(),
            appearance: if *show_pinned.clone() { Appearance::Primary } else { Appearance::Secondary },
            text: text_builder("messages.pin-view"),
            tooltip: tooltip_builder("messages.pin-view", arrow_top),
            onpress: move |_| {
                show_pinned.set(true);
                show_more.set(false);
            }
        }
        Button {
            icon: Icon::PhoneArrowUpRight,
            disabled: !state.read().configuration.developer.experimental_features || *call_pending.current() || call_in_progress,
            aria_label: "Call".into(),
            appearance: Appearance::Secondary,
            text: text_builder(if !state.read().configuration.developer.experimental_features {"uplink.coming-soon"} else {"uplink.call"}),
            tooltip: tooltip_builder(if !state.read().configuration.developer.experimental_features {"uplink.coming-soon"} else {"uplink.call"}, arrow_top),
            onpress: move |_| {
                if chat_data.read().active_chat.is_initialized {
                    ch.send(ControlsCmd::VoiceCall{
                        participants: chat_data.read().active_chat.other_participants().iter().map(|x| x.did_key()).collect(),
                        conversation_id: chat_data.read().active_chat.id()
                    });
                    call_pending.set(true);
                    show_more.set(false);
                }
            }
        },
        Button {
            icon: Icon::VideoCamera,
            disabled: true,
            aria_label: "Videocall".into(),
            appearance: Appearance::Secondary,
            text: text_builder("uplink.coming-soon"),
            tooltip: tooltip_builder("uplink.coming-soon", arrow_top_right),
        },
    ));

    let pinned = cx.render(rsx!(show_pinned.then(|| rsx!(
        Modal {
            open: true,
            right: "8px",
            transparent: true,
            change_horizontal_position: true,
            with_title: get_local_text("messages.pin-view"),
            onclose: move |_| {
                show_pinned.set(false);
            },
            if chat_data.read().active_chat.is_initialized {
                rsx!(PinnedMessages{ show_pinned: show_pinned.clone()})
            }
        }
    )),));

    if minimal {
        return cx.render(rsx!(
            div {
                z_index: 100,
                Button {
                    icon: Icon::EllipsisVertical,
                    aria_label: "control-group".into(),
                    appearance: Appearance::Primary,
                    tooltip: if *show_more.get() {
                        cx.render(rsx!(()))
                    } else {
                        cx.render(rsx!(Tooltip {
                            arrow_position: ArrowPosition::TopRight,
                            text: get_local_text("messages.control-group")
                        }))
                    },
                    onpress: move |_| {
                        let current = show_more.get();
                        show_more.set(!current);
                    }
                }
            },
            show_more.then(|| {
                rsx!(InvisibleCloser {
                        classes: "minimal-chat-button-group-out".into(),
                        onclose: move |_|{
                            show_more.set(false);
                        },
                    }
                    div {
                        class: "minimal-chat-button-group",
                        buttons
                    })
            }),
            pinned
        ));
    }
    cx.render(rsx!(buttons, pinned))
}
