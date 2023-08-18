use std::ops::Range;

use chrono::{DateTime, Utc};
use common::{
    language::get_local_text,
    state::{Chat, Identity, State},
    warp_runner::{thumbnail_to_base64, ui_adapter::Message, RayGunCmd, WarpCmd},
    WARP_CMD_CH,
};
use dioxus::prelude::*;

use dioxus_desktop::use_eval;
use futures::StreamExt;
use kit::components::{embeds::file_embed::FileEmbed, message::ChatText, user_image::UserImage};
use uuid::Uuid;
use warp::{logging::tracing::log, raygun::PinState};

pub enum ChannelCommand {
    RemovePinnedMessage(Uuid, Uuid),
    ScrollToUnloaded(Uuid, Uuid, DateTime<Utc>),
}

type FetchedMessages = (
    Uuid,
    Uuid,
    Vec<common::warp_runner::ui_adapter::Message>,
    bool,
);

#[derive(Props, Eq, PartialEq)]
pub struct Props {
    active_chat: Chat,
}

#[allow(non_snake_case)]
pub fn PinnedMessages(cx: Scope<Props>) -> Element {
    log::trace!("rendering pinned_messages");
    let chat = &cx.props.active_chat;
    let state = use_shared_state::<State>(cx)?;
    let newely_fetched_messages: &UseRef<Option<FetchedMessages>> = use_ref(cx, || None);

    if let Some((id, message_id, m, has_more)) = newely_fetched_messages.write_silent().take() {
        // We need to enqueue the scrolling since at this point the message components are not updated yet
        state.write_silent().enqueue_message_scroll(&id, message_id);
        state.write().update_chat_messages(id, m);
        if !has_more {
            log::debug!("finished loading chat: {id}");
            state.write().finished_loading_chat(id);
        }
    }

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<ChannelCommand>| {
        to_owned![newely_fetched_messages];
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
                                newely_fetched_messages.set(Some((
                                    conversation_id,
                                    message_id,
                                    m,
                                    has_more,
                                )));
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

    let script = include_str!("./script.js");
    let eval = use_eval(cx);
    use_effect(cx, (), |_| {
        to_owned![eval];
        async move {
            eval(script.to_string());
        }
    });

    cx.render(rsx!(div {
        id: "pinned-messages-container",
        class: "hidden",
        aria_label: "pinned-messages-label",
        div {
            class: "pinned-header",
            get_local_text("messages.pin-view")
        }
        div {
            class: "pinned-messages",
            if chat.pinned_messages.is_empty() {
                rsx!(div {
                    class: "pinned-empty",
                    div {
                        get_local_text("messages.pinned-none")
                    }
                })
            } else {
                rsx!(chat.pinned_messages.iter().map(|message|{
                    let sender = state.read().get_identity(&message.sender());
                    let time = message.date().format(&get_local_text("uplink.date-time-format")).to_string();
                    rsx!(PinnedMessage {
                        message: Message { inner: message.clone(), in_reply_to: None, key: String::default()},
                        sender: sender,
                        onremove: move |(_,msg): (Event<MouseData>, warp::raygun::Message)| {
                            let conv = &msg.conversation_id();
                            ch.send(ChannelCommand::RemovePinnedMessage(*conv, msg.id()))
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
    // todo: should be a warp::raygun::Message
    message: Message,
    #[props(!optional)]
    sender: Option<Identity>,
    onremove: EventHandler<'a, (Event<MouseData>, warp::raygun::Message)>,
    time: String,
    is_loaded: bool,
    ch: Coroutine<ChannelCommand>,
}

#[allow(non_snake_case)]
pub fn PinnedMessage<'a>(cx: Scope<'a, PinnedMessageProp<'a>>) -> Element<'a> {
    let message = &cx.props.message;
    let chat_id = message.inner.conversation_id();
    let id = message.inner.id();
    let date = message.inner.date();
    let attachments = message.inner.attachments();

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
                                display: "inline-flex",
                                p {
                                    class: "pinned-sender",
                                    sender.username()
                                },
                                div {
                                    class: "pinned-button-container",
                                    button {
                                        class: "pinned-buttons",
                                        onclick: move |_| {
                                            if cx.props.is_loaded {
                                                eval(include_str!("../scroll_to_message.js").replace("$UUID", &id.to_string()));
                                            } else {
                                                cx.props.ch.send(ChannelCommand::ScrollToUnloaded(chat_id, id, date))
                                            }
                                        },
                                        get_local_text("messages.pin-button-goto")
                                    },
                                    button {
                                        class: "pinned-buttons",
                                        onclick: move |e| {
                                            cx.props.onremove.call((e, cx.props.message.inner.clone()));
                                        },
                                        get_local_text("messages.pin-button-unpin"),
                                    }
                                }
                            })
                        }),
                        p {
                            class: "pinned-sender-time",
                            "{cx.props.time}"
                        }
                    }
                    ChatText {
                        text: message.inner.value().join("\n"),
                        remote: true,
                        pending: false,
                    }
                },
                has_attachments.then(|| {
                    rsx!(
                        div {
                            class: "attachment-list",
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
