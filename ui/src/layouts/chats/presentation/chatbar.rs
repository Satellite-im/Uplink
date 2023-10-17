use std::{
    path::PathBuf,
    time::{Duration, Instant},
};

use common::{
    icons::{self},
    language::{get_local_text, get_local_text_with_args},
    state::{Action, Identity, State},
    warp_runner::{RayGunCmd, WarpCmd},
    MAX_FILES_PER_MESSAGE, STATIC_ARGS, WARP_CMD_CH,
};
use dioxus::prelude::*;
use futures::{channel::oneshot, StreamExt};
use kit::{
    components::{
        indicator::{Platform, Status},
        user_image::UserImage,
    },
    elements::{
        button::Button,
        tooltip::{ArrowPosition, Tooltip},
        Appearance,
    },
    layout::chatbar::{Chatbar, Reply},
};
use once_cell::sync::Lazy;
use regex::Regex;
use rfd::FileDialog;
use uuid::Uuid;
use warp::{
    crypto::DID,
    logging::tracing::log,
    raygun::{self, Location},
};

const MAX_CHARS_LIMIT: usize = 1024;
pub static EMOJI_REGEX: Lazy<Regex> = Lazy::new(|| Regex::new(":[^:]{2,}:?$").unwrap());
use super::context_menus::FileLocation as FileLocationContext;
use crate::{
    components::{files::attachments::Attachments, paste_files_with_shortcut},
    layouts::chats::{data::ChatProps, scripts::SHOW_CONTEXT},
    layouts::{
        chats::data::{ChatData, ScrollBtn, DEFAULT_MESSAGES_TO_TAKE},
        storage::send_files_layout::{modal::SendFilesLayoutModal, SendFilesStartLocation},
    },
    utils::{
        build_user_from_identity,
        clipboard::clipboard_data::{
            check_if_there_is_file_or_string_in_clipboard, ClipboardDataType,
        },
    },
};

type ChatInput = (Vec<String>, Uuid, Option<Uuid>, Option<Uuid>);

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
pub fn get_chatbar<'a>(cx: &'a Scoped<'a, ChatProps>) -> Element<'a> {
    log::trace!("get_chatbar");
    let state = use_shared_state::<State>(cx)?;
    let chat_data = use_shared_state::<ChatData>(cx)?;
    let scroll_btn = use_shared_state::<ScrollBtn>(cx)?;
    state.write_silent().scope_ids.chatbar = Some(cx.scope_id().0);

    let is_loading = !chat_data.read().active_chat.is_initialized;
    let active_chat_id = chat_data.read().active_chat.id();
    let chat_id = chat_data.read().active_chat.id();
    let can_send = use_state(cx, || state.read().active_chat_has_draft());
    let update_script = use_state(cx, String::new);
    let upload_button_menu_uuid = &*cx.use_hook(|| Uuid::new_v4().to_string());
    let show_storage_modal = use_state(cx, || false);

    let emoji_suggestions = use_state(cx, Vec::new);

    let with_scroll_btn = scroll_btn.read().get(chat_id);

    // if the active chat is scrolled up and a message is received, want to increment unreads
    // but the needed information isn't accessible in main.rs. so a flag was added to State
    // and is set here in the chatbar. This was done here instead of in messages.rs as
    // an attempted optimization - don't want to re-render messages whenever scroll_btn
    // is written to, which could be a lot.
    state
        .write_silent()
        .set_chat_scrolled(chat_id, with_scroll_btn);

    // this was moved from chat/mod.rs so that unreads doesn't get cleared automatically.
    if !with_scroll_btn && state.read().chats().active_chat_has_unreads() {
        state.write().mutate(Action::ClearActiveUnreads);
    }

    let update_send = move || {
        let valid = state.read().active_chat_has_draft()
            || !state
                .read()
                .get_active_chat()
                .map(|f| f.files_attached_to_send)
                .unwrap_or_default()
                .is_empty();
        if !can_send.get().eq(&valid) {
            can_send.set(valid);
        }
    };
    update_send();

    let mut files_attached = state
        .read()
        .get_active_chat()
        .map(|f| f.files_attached_to_send)
        .unwrap_or_default();

    if files_attached.len() > MAX_FILES_PER_MESSAGE {
        files_attached.truncate(MAX_FILES_PER_MESSAGE);
        state
            .write()
            .mutate(Action::SetChatAttachments(chat_id, files_attached));
    }

    // todo: update the typing indicator in a coroutine
    let my_id = state.read().did_key();
    let users_typing: Vec<DID> = chat_data
        .read()
        .active_chat
        .typing_indicator
        .iter()
        .filter(|(did, _)| *did != &my_id)
        .map(|(did, _)| did.clone())
        .collect();
    let users_typing = state.read().get_identities(&users_typing);

    // this is used to scroll to the bottom of the chat.
    let scroll_ch = use_coroutine(cx, |mut rx: UnboundedReceiver<Uuid>| {
        to_owned![chat_data, state];
        async move {
            while let Some(conv_id) = rx.next().await {
                match crate::layouts::chats::presentation::chat::coroutines::fetch_most_recent(
                    conv_id,
                    DEFAULT_MESSAGES_TO_TAKE,
                )
                .await
                {
                    Ok((messages, behavior)) => {
                        log::debug!("re-init messages with most recent");
                        chat_data.write().set_active_chat(
                            &state.read(),
                            &conv_id,
                            behavior,
                            messages,
                        );
                    }
                    Err(e) => log::error!("{e}"),
                }
            }
        }
    });

    let msg_ch = use_coroutine(cx, |mut rx: UnboundedReceiver<ChatInput>| {
        to_owned![state];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some((msg, conv_id, ui_msg_id, reply)) = rx.next().await {
                let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();
                let attachments = state
                    .read()
                    .get_active_chat()
                    .map(|f| f.files_attached_to_send)
                    .unwrap_or_default();
                let msg_clone = msg.clone();
                let cmd = match reply {
                    Some(reply_to) => RayGunCmd::Reply {
                        conv_id,
                        reply_to,
                        msg,
                        attachments,
                        rsp: tx,
                    },
                    None => RayGunCmd::SendMessage {
                        conv_id,
                        msg,
                        attachments,
                        ui_msg_id,
                        rsp: tx,
                    },
                };
                let attachments = state
                    .read()
                    .get_active_chat()
                    .map(|f| f.files_attached_to_send)
                    .unwrap_or_default();
                state
                    .write_silent()
                    .mutate(Action::ClearChatAttachments(conv_id));
                let attachment_files: Vec<String> = attachments
                    .iter()
                    .map(|p| {
                        let pathbuf = match p {
                            Location::Disk { path } => path.clone(),
                            Location::Constellation { path } => PathBuf::from(path),
                        };
                        pathbuf
                            .file_name()
                            .map_or_else(String::new, |ostr| ostr.to_string_lossy().to_string())
                    })
                    .collect();
                if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(cmd)) {
                    log::error!("failed to send warp command: {}", e);
                    state.write().decrement_outgoing_messages(
                        conv_id,
                        msg_clone,
                        attachment_files,
                        ui_msg_id,
                    );
                    continue;
                }

                let rsp = rx.await.expect("command canceled");
                if let Err(e) = rsp {
                    log::error!("failed to send message: {}", e);
                    state.write().decrement_outgoing_messages(
                        conv_id,
                        msg_clone,
                        attachment_files,
                        ui_msg_id,
                    );
                }
            }
        }
    });

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
    let enable_paste_shortcut = use_ref(cx, || true);

    use_future(cx, (), |_| {
        to_owned![enable_paste_shortcut];
        async move {
            loop {
                let clipboard_data_type = tokio::task::spawn_blocking(|| {
                    check_if_there_is_file_or_string_in_clipboard()
                        .unwrap_or(ClipboardDataType::String)
                })
                .await
                .expect("Should succeed");
                match clipboard_data_type {
                    ClipboardDataType::File => {
                        if !*enable_paste_shortcut.read() {
                            enable_paste_shortcut.with_mut(|i| *i = true);
                        }
                    }
                    _ => {
                        if *enable_paste_shortcut.read() {
                            enable_paste_shortcut.with_mut(|i| *i = false);
                        }
                    }
                }
                tokio::time::sleep(Duration::from_millis(250)).await;
            }
        }
    });

    use_future(cx, &active_chat_id, |current_chat| async move {
        loop {
            tokio::time::sleep(Duration::from_secs(STATIC_ARGS.typing_indicator_refresh)).await;
            if !current_chat.is_nil() {
                local_typing_ch1.send(TypingIndicator::Refresh(current_chat));
            }
        }
    });

    let msg_valid = |msg: &[String]| {
        (!msg.is_empty() && msg.iter().any(|line| !line.trim().is_empty()))
            || !state
                .read()
                .get_active_chat()
                .map(|f| f.files_attached_to_send)
                .unwrap_or_default()
                .is_empty()
    };

    let submit_fn = move || {
        local_typing_ch.send(TypingIndicator::NotTyping);

        let files_to_upload = state
            .read()
            .get_active_chat()
            .as_ref()
            .map(|d| d.files_attached_to_send.clone())
            .unwrap_or_default();

        let msg = state
            .read()
            .get_active_chat()
            .as_ref()
            .and_then(|d| d.draft.clone())
            .unwrap_or_default()
            .lines()
            .map(|x| x.trim_end().to_string())
            .collect::<Vec<String>>();

        if !active_chat_id.is_nil() {
            state
                .write()
                .mutate(Action::SetChatDraft(active_chat_id, String::new()));
        }

        emoji_suggestions.set(vec![]);

        if !msg_valid(&msg) || active_chat_id.is_nil() {
            return;
        }

        can_send.set(false);
        if STATIC_ARGS.use_mock {
            state.write().mutate(Action::MockSend(active_chat_id, msg));
        } else {
            let replying_to = state.read().chats().get_replying_to();
            if replying_to.is_some() {
                state.write().mutate(Action::CancelReply(active_chat_id));
            }
            let ui_id = state
                .write()
                .increment_outgoing_messages(msg.clone(), &files_to_upload);
            msg_ch.send((msg, active_chat_id, ui_id, replying_to));
        }
    };

    let extensions = &state.read().ui.extensions;
    let ext_renders = extensions
        .values()
        .filter(|(is_enabled, ext)| {
            ext.details().location == extensions::Location::Chatbar && *is_enabled
        })
        .map(|(_, ext)| ext.render(cx.scope))
        .collect::<Vec<_>>();

    let disabled = !state.read().can_use_active_chat();
    // todo: don't define a hook so far down
    let error = use_state(cx, || (false, active_chat_id));
    let value_chatbar = state
        .read()
        .get_active_chat()
        .as_ref()
        .and_then(|d| d.draft.clone())
        .unwrap_or_default();

    if value_chatbar.len() >= MAX_CHARS_LIMIT && !error.0 {
        error.set((true, active_chat_id));
    } else if value_chatbar.len() < MAX_CHARS_LIMIT && error.0 {
        error.set((false, active_chat_id));
    }

    let validate_max = move || {
        let value_chatbar = state
            .read()
            .get_active_chat()
            .as_ref()
            .and_then(|d| d.draft.clone())
            .unwrap_or_default();
        if value_chatbar.len() >= MAX_CHARS_LIMIT {
            error.set((true, active_chat_id));
        } else if value_chatbar.len() < MAX_CHARS_LIMIT && error.0 {
            error.set((false, active_chat_id));
        }
    };
    let placeholder_text = if !state.read().ui.is_minimal_view() {
        get_local_text("messages.say-something-placeholder")
    } else {
        "...".to_string()
    };

    let typing_users: Vec<String> = users_typing.iter().map(|id| (*id).username()).collect();

    let chatbar = cx.render(rsx!(
        Chatbar {
            key: "{active_chat_id}",
            id: format!("{}-chatbar", active_chat_id.to_string()),
            loading: is_loading,
            placeholder: placeholder_text,
            typing_users: typing_users,
            is_disabled: disabled,
            ignore_focus: cx.props.ignore_focus,
            onchange: move |v: String| {
                if !active_chat_id.is_nil() {
                    state.write_silent().mutate(Action::SetChatDraft(active_chat_id, v));
                    validate_max();
                    update_send();
                    local_typing_ch.send(TypingIndicator::Typing(active_chat_id));
                }
            },
            value: state.read().get_active_chat().as_ref().and_then(|d| d.draft.clone()).unwrap_or_default(),
            onreturn: move |_| submit_fn(),
            extensions: cx.render(rsx!(for node in ext_renders { rsx!(node) })),
            emoji_suggestions: emoji_suggestions,
            oncursor_update: move |(mut v, p): (String, i64)| {
                if !active_chat_id.is_nil() {
                    let sub: String = v.chars().take(p as usize).collect();
                    let capture = EMOJI_REGEX.captures(&sub);
                    match capture {
                        Some(emoji) => {
                            let emoji = &emoji[0];
                            if emoji.contains(char::is_whitespace) {
                                emoji_suggestions.set(vec![]);
                                return;
                            }
                            if emoji.ends_with(':') {
                                // Replace emoji alias
                                let alias = emoji.replace(':', "");
                                let s = state.read().ui.emojis.get_matching_emoji(&alias, true);
                                let replacement = s.first();
                                if let Some((emoji, _)) = replacement {
                                    v = v.replace(&sub, &sub.replace(&format!(":{alias}:"), emoji));
                                    state.write().mutate(Action::SetChatDraft(active_chat_id, v));
                                }
                                emoji_suggestions.set(vec![])
                            } else {
                                //Suggest emojis
                                let alias = emoji.replace(':', "");
                                emoji_suggestions
                                    .set(state.read().ui.emojis.get_matching_emoji(&alias, false))
                            }
                        }
                        None => emoji_suggestions.set(vec![]),
                    }
                }
            },
            on_emoji_click: move |(emoji, _, p): (String, String, i64)| {
                if !active_chat_id.is_nil() {
                    let mut draft = state
                        .read()
                        .get_active_chat()
                        .as_ref()
                        .and_then(|d| d.draft.clone())
                        .unwrap_or_default();
                    let sub: String = draft.chars().take(p as usize).collect();
                    let capture = EMOJI_REGEX.captures(&sub);
                    if let Some(e) = capture {
                        draft = draft.replace(&sub, &sub.replace(&e[0].to_string(), &emoji));
                        state
                            .write()
                            .mutate(Action::SetChatDraft(active_chat_id, draft));
                    }
                    emoji_suggestions.set(vec![])
                }
            },
            controls: cx.render(
                rsx!(
                    Button {
                        icon: icons::outline::Shape::ChevronDoubleRight,
                        disabled: is_loading || disabled,
                        appearance: if * can_send.get() { Appearance::Primary } else { Appearance::Secondary },
                        aria_label: "send-message-button".into(),
                        onpress: move |_| submit_fn(),
                        tooltip: cx.render(rsx!(Tooltip {
                            arrow_position: ArrowPosition::Bottom,
                            text :get_local_text("uplink.send"),
                        })),
                    }
                ),
            ),
            with_replying_to: (!disabled).then(|| {
                cx.render(
                    rsx!(
                        chat_data.read().active_chat.replying_to().map(|msg| {
                            let our_did = state.read().did_key();
                            let msg_owner = if chat_data.read().active_chat.my_id().did_key() == msg.sender() {
                                Some(chat_data.read().active_chat.my_id())
                            } else {
                                chat_data.read().active_chat.other_participants().iter().find(|x| x.did_key() == msg.sender()).cloned()
                            };

                            let (platform, status, profile_picture) = get_platform_and_status(msg_owner.as_ref());

                            rsx!(
                                Reply {
                                    label: get_local_text("messages.replying"),
                                    remote: our_did != msg.sender(),
                                    onclose: move |_| {
                                        state.write().mutate(Action::CancelReply(chat_data.read().active_chat.id()))
                                    },
                                    attachments: msg.attachments(),
                                    message: msg.value().join("\n"), 
                                    markdown: state.read().ui.should_transform_markdown_text(),
                                    UserImage {
                                        image: profile_picture,
                                        platform: platform,
                                        status: status,
                                    },
                                }
                            )
                        })
                    ),
                )
            }).unwrap_or(None),
            with_file_upload: cx.render(
                rsx!(
                    Button {
                        icon: icons::outline::Shape::Plus,
                        disabled: is_loading || disabled,
                        aria_label: "upload-button".into(),
                        appearance: Appearance::Primary,
                        onpress: move |e: Event<MouseData>| {
                            let mouse_data = e;
                            let script = SHOW_CONTEXT
                                .replace("UUID", upload_button_menu_uuid)
                                .replace("$PAGE_X", &mouse_data.page_coordinates().x.to_string())
                                .replace("$PAGE_Y", &mouse_data.page_coordinates().y.to_string());
                            update_script.set(script);
                        },
                        tooltip: cx.render(rsx!(
                            Tooltip {
                                arrow_position: ArrowPosition::Bottom,
                                text: get_local_text("files.upload"),
                            }
                        )),
                    }
                    FileLocationContext {
                        id: upload_button_menu_uuid,
                        update_script: update_script,
                        on_press_storage: move |_| {
                            show_storage_modal.set(true);
                        },
                        on_press_local_disk: move |_| {
                            if disabled {
                                return;
                            }
                            if let Some(new_files) = FileDialog::new()
                            .set_directory(dirs::home_dir().unwrap_or_default())
                            .pick_files()
                        {
                            let new_files: Vec<Location> = new_files.iter()
                            .map(|path| Location::Disk { path: path.clone() })
                            .collect();
                            let mut current_files: Vec<_> =  state.read().get_active_chat().map(|f| f.files_attached_to_send)
                            .unwrap_or_default().drain(..).filter(|x| !new_files.contains(x)).collect();
                            current_files.extend(new_files);
                            state.write().mutate(Action::SetChatAttachments(chat_id, current_files));
                            update_send();
                            }
                        },
                    }
                ),
            )
        }
        error.0.then(|| rsx!(
            p {
                class: "chatbar-error-input-message",
                aria_label: "chatbar-input-error",
                get_local_text_with_args("warning-messages.maximum-of", vec![("num", MAX_CHARS_LIMIT.into())])
            }
        ))
    ));

    cx.render(rsx!(
        if state.read().ui.metadata.focused && *enable_paste_shortcut.read() {
            rsx!(paste_files_with_shortcut::PasteFilesShortcut {
                on_paste: move |files_local_path: Vec<PathBuf>| {
                    if !files_local_path.is_empty() {
                        let new_files: Vec<Location> = files_local_path
                        .iter()
                        .map(|path| Location::Disk { path: path.clone() })
                        .collect();
                    let mut current_files: Vec<_> = state
                        .read()
                        .get_active_chat()
                        .map(|f| f.files_attached_to_send)
                        .unwrap_or_default()
                        .drain(..)
                        .filter(|x| !new_files.contains(x))
                        .collect();
                        current_files.extend(new_files);
                    state
                        .write()
                        .mutate(Action::SetChatAttachments(chat_id, current_files));
                    }
                }})}
                SendFilesLayoutModal {
                    send_files_from_storage: show_storage_modal,
                    send_files_start_location: SendFilesStartLocation::Chats,
                    on_send: move |(files_location, _): (Vec<Location>, _)| {
                        let mut new_files_to_upload: Vec<_> = state.read().get_active_chat().map(|f| f.files_attached_to_send)
                        .unwrap_or_default()
                        .iter()
                        .filter(|file_location| {
                            !files_location.contains(file_location)
                        })
                        .cloned()
                        .collect();
                        new_files_to_upload.extend(files_location);
                        state.write().mutate(Action::SetChatAttachments(chat_id, new_files_to_upload));
                        update_send();
                    },
                },
        div {
            class: "chatbar-container",
            with_scroll_btn.then(|| {
                rsx!(div {
                    class: "btn scroll-bottom-btn",
                    onclick: move |_| {
                        scroll_btn.write().clear(chat_id);
                        state.write().mutate(Action::ClearUnreads(chat_id));
                        // note that if scroll_behavior.on_scroll_end == ScrollBehavior::DoNothing then it isn't necessary to 
                        // fetch more messages - one could just use a regular javascript to scroll to the end of the page. 
                        // however, this is easier and seems to work well enough. 
                        scroll_ch.send(chat_id);
                    },
                    get_local_text("messages.scroll-bottom"),
                })
            })
            if state.read().ui.metadata.focused && *enable_paste_shortcut.read() {
                rsx!(paste_files_with_shortcut::PasteFilesShortcut {
                    on_paste: move |files_local_path: Vec<PathBuf>| {
                        if !files_local_path.is_empty() {
                            let mut new_files_to_upload: Vec<_> = state.read().get_active_chat().map(|f| f.files_attached_to_send)
                                .unwrap_or_default()
                                .iter()
                                .filter(|file_location| {
                                    match file_location {
                                        Location::Disk { path } => {
                                            !files_local_path.contains(path)
                                        },
                                        Location::Constellation { .. } => {
                                            true
                                        }
                                    }
                                })
                                .cloned()
                                .collect();
                            let local_disk_files: Vec<Location> = files_local_path
                                .iter()
                                .map(|path| Location::Disk { path: path.clone() })
                                .collect();
                            new_files_to_upload.extend(local_disk_files);
                            state.write().mutate(Action::SetChatAttachments(chat_id, new_files_to_upload));
                        }
                    },
                })
            }
        },
        Attachments {
            chat_id: chat_id,
            files_to_attach: state.read().get_active_chat().map(|f| f.files_attached_to_send).unwrap_or_default(),
            on_remove: move |files_attached| {
                state.write().mutate(Action::SetChatAttachments(chat_id, files_attached));
                update_send();
            }
        },
        chatbar
    ))
}

fn get_platform_and_status(msg_sender: Option<&Identity>) -> (Platform, Status, String) {
    let sender = match msg_sender {
        Some(identity) => identity,
        None => return (Platform::Desktop, Status::Offline, String::new()),
    };
    let user_sender = build_user_from_identity(sender);
    (user_sender.platform, user_sender.status, user_sender.photo)
}
