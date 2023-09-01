use std::ops::Range;

use chrono::{DateTime, Utc};
use common::{
    language::get_local_text,
    state::{Chat, Identity, State},
    warp_runner::{thumbnail_to_base64, RayGunCmd, WarpCmd},
    WARP_CMD_CH,
};
use dioxus::prelude::*;

use futures::StreamExt;
use kit::components::{embeds::file_embed::FileEmbed, message::ChatText, user_image::UserImage};
use uuid::Uuid;
use warp::{logging::tracing::log, raygun::PinState};

pub enum ChannelCommand {
    RemovePinnedMessage(Uuid, Uuid),
    ScrollToUnloaded(Uuid, Uuid, DateTime<Utc>),
}

#[derive(Props)]
pub struct Props<'a> {
    active_chat: Chat,
    onclose: EventHandler<'a, ()>,
}

#[allow(non_snake_case)]
pub fn PinnedMessages<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    log::trace!("rendering pinned_messages");
    let chat = &cx.props.active_chat;
    let state = use_shared_state::<State>(cx)?;

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<ChannelCommand>| {
        to_owned![state];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(cmd) = rx.next().await {
                match cmd {
                    ChannelCommand::RemovePinnedMessage(conversation_id, message_id) => {
                        let (tx, rx) = futures::channel::oneshot::channel();
                        if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::Pin {
                            conversation_id,
                            message_id,
                            pinstate: PinState::Unpin,
                            rsp: tx,
                        })) {
                            log::error!("failed to send warp command: {}", e);
                            continue;
                        }

                        let res = rx.await.expect("command canceled");
                        if let Err(e) = res {
                            log::error!("failed to pin message: {}", e);
                        }
                    }
                    ChannelCommand::ScrollToUnloaded(conversation_id, message_id, message_date) => {
                        let (tx, rx) = futures::channel::oneshot::channel();
                        if let Err(e) =
                            warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::FetchMessagesBetween {
                                conv_id: conversation_id,
                                date_range: Range {
                                    start: message_date,
                                    end: Utc::now(),
                                },
                                rsp: tx,
                            }))
                        {
                            log::error!("failed to send warp command: {}", e);
                            continue;
                        }

                        match rx.await.expect("command canceled") {
                            Ok((m, has_more)) => {
                                state
                                    .write_silent()
                                    .enqueue_message_scroll(&conversation_id, message_id);
                                state.write().update_chat_messages(conversation_id, m);
                                if !has_more {
                                    log::debug!("finished loading chat: {conversation_id}");
                                    state.write().finished_loading_chat(conversation_id);
                                }
                            }
                            Err(e) => {
                                log::error!("failed to fetch more message: {}", e);
                            }
                        }
                    }
                }
            }
        }
    });
    cx.render(rsx!(div {
        id: "pinned-messages-container",
        aria_label: "pinned-messages-label",
        div {
            class: "pinned-messages",
            aria_label: "pinned-messages-container",
            if chat.pinned_messages.is_empty() {
                rsx!(div {
                    class: "pinned-empty",
                    aria_label: "pinned-empty",
                    div {
                        get_local_text("messages.pinned-none")
                    }
                })
            } else {
                rsx!(chat.pinned_messages.iter().map(|message|{
                    let sender = state.read().get_identity(&message.sender());
                    let time = message.date().format(&get_local_text("uplink.date-time-format")).to_string();
                    rsx!(PinnedMessage {
                        message: message.clone(),
                        sender: sender,
                        onremove: move |(_,msg): (Event<MouseData>, warp::raygun::Message)| {
                            let conv = &msg.conversation_id();
                            ch.send(ChannelCommand::RemovePinnedMessage(*conv, msg.id()))
                        },
                        onclose: move |_| {
                            cx.props.onclose.call(());
                        },
                        time: time,
                        is_loaded: state.read().message_exist(message),
                        ch: ch.clone()
                    })
                }))
            }
        }
    }))
}

#[derive(Props)]
pub struct PinnedMessageProp<'a> {
    message: warp::raygun::Message,
    #[props(!optional)]
    sender: Option<Identity>,
    onremove: EventHandler<'a, (Event<MouseData>, warp::raygun::Message)>,
    time: String,
    is_loaded: bool,
    ch: Coroutine<ChannelCommand>,
    onclose: EventHandler<'a, ()>,
}

#[allow(non_snake_case)]
pub fn PinnedMessage<'a>(cx: Scope<'a, PinnedMessageProp<'a>>) -> Element<'a> {
    let message = &cx.props.message;
    let chat_id = message.conversation_id();
    let id = message.id();
    let date = message.date();
    let attachments = message.attachments();

    let eval = use_eval(cx);

    let attachment_list = attachments.iter().map(|file| {
        let key = file.id();
        rsx!(FileEmbed {
            key: "{key}",
            filename: file.name(),
            filesize: file.size(),
            thumbnail: thumbnail_to_base64(file),
            with_download_button: false,
            big: false,
            remote: true,
            download_pending: false,
            on_press: move |_| {},
        })
    });
    let has_attachments = !attachments.is_empty();

    cx.render(rsx!(
        div {
            class: "pinned-message-wrap",
            aria_label: "pinned-message-wrap",
            cx.props.sender.as_ref().map(|sender| {
                rsx!(UserImage {
                    image: sender.profile_picture(),
                    platform: sender.platform().into(),
                })
            }),
            div {
                class: "pinned-message",
                aria_label: "pinned-message",
                white_space: "pre-wrap",
                div{
                    class: "pinned-content-container",
                    div {
                        class: "pinned-sender-container",
                        cx.props.sender.as_ref().map(|sender| {
                            rsx!(div {
                                class: "full-flex",
                                p {
                                    class: "pinned-sender",
                                    aria_label: "pinned-sender",
                                    sender.username()
                                },
                                div {
                                    class: "pinned-button-container",
                                    aria_label: "pinned-button-container",
                                    button {
                                        class: "pinned-buttons",
                                        aria_label: "pin-button-go-to",
                                        onclick: move |_| {
                                            cx.props.onclose.call(());
                                            if cx.props.is_loaded {
                                                let _ = eval(&include_str!("../scroll_to_message.js").replace("$UUID", &id.to_string()));
                                            } else {
                                                cx.props.ch.send(ChannelCommand::ScrollToUnloaded(chat_id, id, date));
                                            }
                                        },
                                        get_local_text("messages.pin-button-goto")
                                    },
                                    button {
                                        class: "pinned-buttons",
                                        aria_label: "pin-button-unpin",
                                        onclick: move |e| {
                                            cx.props.onremove.call((e, cx.props.message.clone()));
                                        },
                                        get_local_text("messages.pin-button-unpin"),
                                    }
                                }
                            })
                        }),
                        p {
                            class: "pinned-sender-time",
                            aria_label: "pinned-time",
                            "{cx.props.time}"
                        }
                    }
                    ChatText {
                        text: message.value().join("\n"),
                        remote: true,
                        pending: false,
                    }
                },
                has_attachments.then(|| {
                    rsx!(
                        div {
                            class: "attachment-list",
                            aria_label: "pinned-attachments",
                            attachment_list.map(|list| {
                                rsx!(list)
                            })
                        }
                    )
                })
            }
        }
    ))
}
