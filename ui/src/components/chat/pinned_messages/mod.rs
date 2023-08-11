use common::{
    language::get_local_text,
    state::{Chat, Identity, State},
    warp_runner::{
        thumbnail_to_base64,
        ui_adapter::{self, Message},
        RayGunCmd, WarpCmd,
    },
    WARP_CMD_CH,
};
use dioxus::prelude::*;

use dioxus_desktop::use_eval;
use futures::StreamExt;
use kit::components::{embeds::file_embed::FileEmbed, message::ChatText, user_image::UserImage};
use uuid::Uuid;
use warp::{logging::tracing::log, raygun::PinState};

pub const SCROLL_MESSAGE: &str = r#"
    var message = document.getElementById("message-$UUID-false")
    console.log("TEST m ", message, "====id:   message-$UUID-false")
    message.scrollIntoView({ behavior: 'smooth', block: 'end' })
    var pinned = document.getElementById("pinned-messages-container")
    pinned.classList.add("hidden")
"#;

enum ChannelCommand {
    FetchPinnedMessages(Uuid, usize, usize),
    RemovePinnedMessage(warp::raygun::Message),
}

#[derive(Props, Eq, PartialEq)]
pub struct Props {
    #[props(!optional)]
    active_chat: Option<Chat>,
}

#[allow(non_snake_case)]
pub fn PinnedMessages(cx: Scope<Props>) -> Element {
    log::trace!("rendering pinned_messages");
    let state = use_shared_state::<State>(cx)?;
    let _loading = use_state(cx, || true);
    let newely_fetched_messages: &UseRef<Option<(Uuid, Vec<ui_adapter::Message>, bool)>> =
        use_ref(cx, || None);

    if let Some((id, m, _)) = newely_fetched_messages.write_silent().take() {
        state.write().update_pinned_chat_messages(id, m);
    }

    let chat = match &cx.props.active_chat {
        Some(c) => c,
        None => return cx.render(rsx!(())),
    };

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<ChannelCommand>| {
        to_owned![newely_fetched_messages];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(cmd) = rx.next().await {
                match cmd {
                    ChannelCommand::FetchPinnedMessages(conv_id, to_fetch, current_len) => {
                        let (tx, rx) = futures::channel::oneshot::channel();
                        if let Err(e) =
                            warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::FetchPinnedMessages {
                                conv_id,
                                to_fetch,
                                current_len,
                                rsp: tx,
                            }))
                        {
                            log::error!("failed to send warp command: {}", e);
                            continue;
                        }

                        match rx.await.expect("command canceled") {
                            Ok((m, has_more)) => {
                                newely_fetched_messages.set(Some((conv_id, m, has_more)));
                            }
                            Err(e) => {
                                log::error!("failed to fetch more message: {}", e);
                            }
                        }
                    }
                    ChannelCommand::RemovePinnedMessage(msg) => {
                        let (tx, rx) = futures::channel::oneshot::channel();
                        if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::Pin {
                            conversation_id: msg.conversation_id(),
                            message_id: msg.id(),
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
        }
    });

    let current_len = chat.pinned_messages.len();
    use_effect(cx, &chat.id, |id| {
        to_owned![ch];
        async move {
            ch.send(ChannelCommand::FetchPinnedMessages(id, 50, current_len));
        }
    });

    let script = include_str!("./script.js");

    cx.render(rsx!(div {
        id: "pinned-messages-container",
        class: "hidden",
        aria_label: "pinned-messages-label",
        script {
            script
        },
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
                    let sender = state.read().get_identity(&message.inner.sender());
                    let time = message.inner.date().format(&get_local_text("uplink.date-time-format")).to_string();
                    rsx!(PinnedMessage {
                        message: message.clone()
                        sender: sender,
                        onremove: move |(_,msg)| {
                            ch.send(ChannelCommand::RemovePinnedMessage(msg))
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
            big: false,
            remote: true,
            download_pending: false,
            on_press: move |_| {},
        })
    });
    let has_attachments = attachments.len() > 0;

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
                                            eval(SCROLL_MESSAGE.replace("$UUID", &id.to_string()));
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
