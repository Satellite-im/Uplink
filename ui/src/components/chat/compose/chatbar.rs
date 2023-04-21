use std::{
    path::PathBuf,
    time::{Duration, Instant},
};

use common::{
    icons,
    language::get_local_text,
    state::{Action, Identity, State},
    warp_runner::{RayGunCmd, WarpCmd},
    STATIC_ARGS, WARP_CMD_CH,
};
use dioxus::prelude::*;
use futures::{channel::oneshot, StreamExt};
use kit::{
    components::{
        file_embed::FileEmbed,
        indicator::{Platform, Status},
        message_typing::MessageTyping,
        user_image::UserImage,
    },
    elements::{
        button::Button,
        tooltip::{ArrowPosition, Tooltip},
        Appearance,
    },
    layout::chatbar::{Chatbar, Reply},
};
use rfd::FileDialog;
use uuid::Uuid;
use warp::{
    crypto::DID,
    logging::tracing::log,
    multipass::identity::{self, IdentityStatus},
    raygun,
};

use crate::utils::build_user_from_identity;

#[derive(Eq, PartialEq)]
enum TypingIndicator {
    // reset the typing indicator timer
    Typing(Uuid),
    // clears the typing indicator, ensuring the indicator
    // will not be refreshed
    NotTyping,
    // resend the typing indicator
    Refresh(Uuid),
}

#[derive(Clone)]
struct TypingInfo {
    pub chat_id: Uuid,
    pub last_update: Instant,
}

// todo: display loading indicator if sending a message that takes a long time to upload attachments
pub fn get_chatbar<'a>(cx: &'a Scoped<'a, super::ComposeProps>) -> Element<'a> {
    log::trace!("get_chatbar");
    let state = use_shared_state::<State>(cx)?;
    state.write_silent().scope_ids.chatbar = Some(cx.scope_id().0);
    let data = &cx.props.data;
    let is_loading = data.is_none();
    let active_chat_id = data.as_ref().map(|d| d.active_chat.id);
    let can_send = use_state(cx, || state.read().active_chat_has_draft());

    let files_to_upload: &UseState<Vec<PathBuf>> = cx.props.upload_files.as_ref().unwrap();
    // used to render the typing indicator
    // for now it doesn't quite work for group messages
    let my_id = state.read().did_key();
    let users_typing: Vec<DID> = data
        .as_ref()
        .map(|data| {
            data.active_chat
                .typing_indicator
                .iter()
                .filter(|(did, _)| *did != &my_id)
                .map(|(did, _)| did.clone())
                .collect()
        })
        .unwrap_or_default();
    let is_typing = !users_typing.is_empty();
    let users_typing = state.read().get_identities(&users_typing);

    let msg_ch = use_coroutine(
        cx,
        |mut rx: UnboundedReceiver<(Vec<String>, Uuid, Option<Uuid>)>| {
            to_owned![files_to_upload];
            async move {
                let warp_cmd_tx = WARP_CMD_CH.tx.clone();
                while let Some((msg, conv_id, reply)) = rx.next().await {
                    let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();
                    let cmd = match reply {
                        Some(reply_to) => {
                            let attachments = files_to_upload.current().to_vec();
                            RayGunCmd::Reply {
                                conv_id,
                                reply_to,
                                msg,
                                attachments,
                                rsp: tx,
                            }
                        }
                        None => {
                            let attachments = files_to_upload.current().to_vec();
                            RayGunCmd::SendMessage {
                                conv_id,
                                msg,
                                attachments,
                                rsp: tx,
                            }
                        }
                    };
                    files_to_upload.set(vec![]);
                    if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(cmd)) {
                        log::error!("failed to send warp command: {}", e);
                        continue;
                    }

                    let rsp = rx.await.expect("command canceled");
                    if let Err(e) = rsp {
                        log::error!("failed to send message: {}", e);
                    }
                }
            }
        },
    );

    // typing indicator notes
    // consider side A, the local side, and side B, the remote side
    // side A -> (typing indicator) -> side B
    // side B removes the typing indicator after a timeout
    // side A doesn't want to send too many typing indicators, say once every 4-5 seconds
    // should we consider matching the timeout with the send frequency so we can closely match if a person is straight up typing for 5 mins straight.

    // tracks if the local participant is typing
    // re-sends typing indicator in response to the Refresh command
    let local_typing_ch = use_coroutine(cx, |mut rx: UnboundedReceiver<TypingIndicator>| {
        // to_owned![];
        async move {
            let mut typing_info: Option<TypingInfo> = None;
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();

            let send_typing_indicator = |conv_id| async move {
                let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();
                let event = raygun::MessageEvent::Typing;
                if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::SendEvent {
                    conv_id,
                    event,
                    rsp: tx,
                })) {
                    log::error!("failed to send warp command: {}", e);
                    // return from the closure
                    return;
                }
                let rsp = rx.await.expect("command canceled");
                if let Err(e) = rsp {
                    log::error!("failed to send typing indicator: {}", e);
                }
            };

            while let Some(indicator) = rx.next().await {
                match indicator {
                    TypingIndicator::Typing(chat_id) => {
                        // if typing_info was none or the chat id changed, send the indicator immediately
                        let should_send_indicator = match typing_info {
                            None => true,
                            Some(info) => info.chat_id != chat_id,
                        };
                        if should_send_indicator {
                            send_typing_indicator.clone()(chat_id).await;
                        }
                        typing_info = Some(TypingInfo {
                            chat_id,
                            last_update: Instant::now(),
                        });
                    }
                    TypingIndicator::NotTyping => {
                        typing_info = None;
                    }
                    TypingIndicator::Refresh(conv_id) => {
                        let info = match &typing_info {
                            Some(i) => i.clone(),
                            None => continue,
                        };
                        if info.chat_id != conv_id {
                            typing_info = None;
                            continue;
                        }
                        // todo: verify duration for timeout
                        let now = Instant::now();
                        if now - info.last_update
                            <= (Duration::from_secs(STATIC_ARGS.typing_indicator_timeout)
                                - Duration::from_millis(500))
                        {
                            send_typing_indicator.clone()(conv_id).await;
                        }
                    }
                }
            }
        }
    });

    // drives the sending of TypingIndicator
    let local_typing_ch1 = local_typing_ch.clone();
    use_future(cx, &active_chat_id, |current_chat| async move {
        loop {
            tokio::time::sleep(Duration::from_secs(STATIC_ARGS.typing_indicator_refresh)).await;
            if let Some(c) = current_chat {
                local_typing_ch1.send(TypingIndicator::Refresh(c));
            }
        }
    });

    let msg_valid = |msg: &[String]| {
        (!msg.is_empty() && msg.iter().any(|line| !line.trim().is_empty()))
            || !files_to_upload.current().is_empty()
    };

    let submit_fn = move || {
        local_typing_ch.send(TypingIndicator::NotTyping);

        let msg = state
            .read()
            .get_active_chat()
            .as_ref()
            .and_then(|d| d.draft.clone())
            .unwrap_or_default()
            .lines()
            .map(|x| x.to_string())
            .collect::<Vec<String>>();

        if let Some(id) = active_chat_id {
            state
                .write()
                .mutate(Action::SetChatDraft(id, String::new()));
        }

        if !msg_valid(&msg) {
            return;
        }
        let id = match active_chat_id {
            Some(i) => i,
            None => return,
        };
        can_send.set(false);
        if STATIC_ARGS.use_mock {
            state.write().mutate(Action::MockSend(id, msg));
        } else {
            let replying_to = state.read().chats().get_replying_to();
            if replying_to.is_some() {
                state.write().mutate(Action::CancelReply(id));
            }
            msg_ch.send((msg, id, replying_to));
        }
    };
    let id = match active_chat_id {
        Some(i) => i,
        None => uuid::Uuid::new_v4(),
    };

    let extensions = &state.read().ui.extensions;
    let ext_renders = extensions
        .values()
        .filter(|ext| ext.enabled())
        .filter(|ext| ext.details().location == extensions::Location::Chatbar)
        .map(|ext| rsx!(ext.render(cx.scope)))
        .collect::<Vec<_>>();

    let disabled = !state.read().can_use_active_chat();

    let inner_state = state.inner();

    let chatbar = cx.render(rsx!(Chatbar {
        key: "{id}",
        id: id.to_string(),
        loading: is_loading,
        placeholder: get_local_text("messages.say-something-placeholder"),
        is_disabled: disabled,
        tooltip: match disabled {
            false => None,
            true => Some(cx.render(rsx!(Tooltip {
                text: get_local_text("messages.not-friends")
                arrow_position: ArrowPosition::Bottom,
            }))),
        },
        onchange: move |v: String| {
            if let Some(id) = &active_chat_id {
                match inner_state.try_borrow_mut() {
                    Ok(state) => {
                        can_send.set(!v.is_empty() || !files_to_upload.get().is_empty());
                        state.write().mutate(Action::SetChatDraft(*id, v));
                    }
                    Err(e) => log::error!("{e}"),
                };
                local_typing_ch.send(TypingIndicator::Typing(*id));
            }
        },
        value: state
            .read()
            .get_active_chat()
            .as_ref()
            .and_then(|d| d.draft.clone())
            .unwrap_or_default(),
        onreturn: move |_| submit_fn(),
        extensions: cx.render(rsx!(
            // Load extensions
            for node in ext_renders {
                rsx!(node)
            }
        )),
        controls: cx.render(rsx!(Button {
            icon: icons::outline::Shape::ChevronDoubleRight,
            disabled: is_loading || disabled,
            appearance: if *can_send.get() {
                Appearance::Primary
            } else {
                Appearance::Secondary
            },
            aria_label: "send-message-button".into(),
            onpress: move |_| submit_fn(),
            tooltip: cx.render(rsx!(Tooltip {
                arrow_position: ArrowPosition::Bottom,
                text: get_local_text("uplink.send"),
            })),
        })),
        with_replying_to: data
            .as_ref()
            .filter(|_| !disabled)
            .map(|data| {
                let active_chat = &data.active_chat;

                cx.render(rsx!(active_chat.replying_to.as_ref().map(|msg| {
                    let our_did = state.read().did_key();
                    let msg_owner = if data.my_id.did_key() == msg.sender() {
                        Some(&data.my_id)
                    } else {
                        data.other_participants
                            .iter()
                            .find(|x| x.did_key() == msg.sender())
                    };
                    let (platform, status, profile_picture) = get_platform_and_status(msg_owner);

                    rsx!(
                        Reply {
                            label: get_local_text("messages.replying"),
                            remote: our_did != msg.sender(),
                            onclose: move |_| {
                                state.write().mutate(Action::CancelReply(active_chat.id))
                            },
                            attachments: msg.attachments(),
                            message: msg.value().join("\n"),
                            UserImage {
                                image: profile_picture,
                                platform: platform,
                                status: status,
                            },
                        }
                    )
                })))
            })
            .unwrap_or(None),
        with_file_upload: cx.render(rsx!(Button {
            icon: icons::outline::Shape::Plus,
            disabled: is_loading || disabled,
            aria_label: "upload-button".into(),
            appearance: Appearance::Primary,
            onpress: move |_| {
                if disabled {
                    return;
                }
                if let Some(new_files) = FileDialog::new()
                    .set_directory(dirs::home_dir().unwrap_or_default())
                    .pick_files()
                {
                    let mut new_files_to_upload: Vec<_> = files_to_upload
                        .current()
                        .iter()
                        .filter(|file_name| !new_files.contains(file_name))
                        .cloned()
                        .collect();
                    new_files_to_upload.extend(new_files);
                    files_to_upload.set(new_files_to_upload);
                    can_send.set(true);
                }
            },
            tooltip: cx.render(rsx!(Tooltip {
                arrow_position: ArrowPosition::Bottom,
                text: get_local_text("files.upload"),
            }))
        }))
    }));

    // todo: possibly show more if multiple users are typing
    let (platform, status, profile_picture) = match users_typing.first() {
        Some(u) => (u.platform(), u.identity_status(), u.profile_picture()),
        None => (
            identity::Platform::Unknown,
            IdentityStatus::Online,
            String::new(),
        ),
    };

    cx.render(rsx!(
        is_typing.then(|| {
            rsx!(MessageTyping {
                user_image: cx.render(rsx!(
                    UserImage {
                        image: profile_picture,
                        platform: platform.into(),
                        status: status.into()
                    }
                ))
            })
        })
        chatbar,
        Attachments {files: files_to_upload.clone(), on_remove: move |b| {
            can_send.set(b | state
                .read()
                .active_chat_has_draft());
        }}
    ))
}

#[derive(Props)]
pub struct AttachmentProps<'a> {
    files: UseState<Vec<PathBuf>>,
    on_remove: EventHandler<'a, bool>,
}

#[allow(non_snake_case)]
fn Attachments<'a>(cx: Scope<'a, AttachmentProps>) -> Element<'a> {
    // todo: pick an icon based on the file extension
    let attachments = cx.render(rsx!(cx
        .props
        .files
        .current()
        .iter()
        .map(|x| x.to_string_lossy().to_string())
        .map(|file_name| {
            rsx!(FileEmbed {
                filename: file_name.clone(),
                remote: false,
                button_icon: icons::outline::Shape::Trash,
                on_press: move |_| {
                    let mut b = false;
                    cx.props.files.with_mut(|files| {
                        files.retain(|x| {
                            let s = x.to_string_lossy().to_string();
                            s != file_name
                        });
                        b = !files.is_empty();
                    });
                    cx.props.on_remove.call(b);
                },
            })
        })));

    cx.render(rsx!(div {
        id: "compose-attachments",
        aria_label: "compose-attachments",
        attachments
    }))
}

fn get_platform_and_status(msg_sender: Option<&Identity>) -> (Platform, Status, String) {
    let sender = match msg_sender {
        Some(identity) => identity,
        None => return (Platform::Desktop, Status::Offline, String::new()),
    };
    let user_sender = build_user_from_identity(sender.clone());
    (user_sender.platform, user_sender.status, user_sender.photo)
}
