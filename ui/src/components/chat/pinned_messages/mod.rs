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

enum ChannelCommand {
    RemovePinnedMessage(Uuid, Uuid),
}

#[derive(Props, Eq, PartialEq)]
pub struct Props {
    active_chat: Chat,
}

#[allow(non_snake_case)]
pub fn PinnedMessages(cx: Scope<Props>) -> Element {
    log::trace!("rendering pinned_messages");
    let chat = &cx.props.active_chat;
    let state = use_shared_state::<State>(cx)?;

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<ChannelCommand>| async move {
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
                        time: time
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
}

#[allow(non_snake_case)]
pub fn PinnedMessage<'a>(cx: Scope<'a, PinnedMessageProp<'a>>) -> Element<'a> {
    let message = &cx.props.message;
    let id = message.inner.id();
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
                                            eval(include_str!("./scroll_to.js").replace("$UUID", &id.to_string()));
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
