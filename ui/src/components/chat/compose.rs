use std::{
    path::PathBuf,
    rc::Rc,
    time::{Duration, Instant},
};

use dioxus::prelude::*;

use futures::{channel::oneshot, StreamExt};

use kit::{
    components::{
        context_menu::{ContextItem, ContextMenu},
        file_embed::FileEmbed,
        indicator::{Platform, Status},
        message::{Message, Order},
        message_group::{MessageGroup, MessageGroupSkeletal},
        message_reply::MessageReply,
        message_typing::MessageTyping,
        user_image::UserImage,
        user_image_group::UserImageGroup,
    },
    elements::{
        button::Button,
        tooltip::{ArrowPosition, Tooltip},
        Appearance,
    },
    layout::{
        chatbar::{Chatbar, Reply},
        topbar::Topbar,
    },
};

use common::icons::outline::Shape as Icon;
use common::{
    state::{self, ui, Action, Chat, Identity, State},
    warp_runner::{RayGunCmd, WarpCmd},
    STATIC_ARGS, WARP_CMD_CH,
};

use common::language::get_local_text;
use dioxus_desktop::{use_eval, use_window};
use rfd::FileDialog;
use uuid::Uuid;
use warp::{
    logging::tracing::log,
    raygun::{self, ReactionState},
};

use crate::{
    components::media::player::MediaPlayer,
    utils::{
        build_participants, build_user_from_identity, convert_status,
        format_timestamp::format_timestamp_timeago,
    },
};

use super::sidebar::build_participants_names;

struct ComposeData {
    active_chat: Chat,
    message_groups: Vec<state::MessageGroup>,
    other_participants: Vec<Identity>,
    active_participant: Identity,
    subtext: String,
    is_favorite: bool,
    first_image: String,
    other_participants_names: String,
    active_media: bool,
    platform: Platform,
}

impl PartialEq for ComposeData {
    fn eq(&self, _other: &Self) -> bool {
        false
    }
}

#[derive(PartialEq, Props)]
struct ComposeProps {
    #[props(!optional)]
    data: Option<Rc<ComposeData>>,
}

#[allow(non_snake_case)]
pub fn Compose(cx: Scope) -> Element {
    log::trace!("rendering compose");
    let state = use_shared_state::<State>(cx)?;
    let data = get_compose_data(cx);
    let data2 = data.clone();

    state.write_silent().ui.current_layout = ui::Layout::Compose;
    if state.read().chats.active_chat_has_unreads() {
        state.write().mutate(Action::ClearActiveUnreads);
    }

    cx.render(rsx!(
        div {
            id: "compose",
            Topbar {
                with_back_button: state.read().ui.is_minimal_view() || state.read().ui.sidebar_hidden,
                with_currently_back: state.read().ui.sidebar_hidden,
                onback: move |_| {
                    let current = state.read().ui.sidebar_hidden;
                    state.write().mutate(Action::SidebarHidden(!current));
                },
                controls: cx.render(rsx!(get_controls{data: data2})),
                get_topbar_children{data: data.clone()}
            },
            data.as_ref().and_then(|data| data.active_media.then(|| rsx!(
                MediaPlayer {
                    settings_text: get_local_text("settings.settings"), 
                    enable_camera_text: get_local_text("media-player.enable-camera"),
                    fullscreen_text: get_local_text("media-player.fullscreen"),
                    popout_player_text: get_local_text("media-player.popout-player"),
                    screenshare_text: get_local_text("media-player.screenshare"),
                    end_text: get_local_text("uplink.end"),
                },
            ))),
            get_messages{data: data.clone()},
            get_chatbar{data: data}
        }
    ))
}

fn get_compose_data(cx: Scope) -> Option<Rc<ComposeData>> {
    let state = use_shared_state::<State>(cx)?;

    // the Compose page shouldn't be called before chats is initialized. but check here anyway.
    if !state.read().chats.initialized {
        return None;
    }

    let s = state.read();
    let active_chat = match s.get_active_chat() {
        Some(c) => c,
        None => return None,
    };
    let message_groups = s.get_sort_messages(&active_chat);
    let other_participants = s.get_without_me(&active_chat.participants);
    let active_participant = other_participants
        .first()
        .cloned()
        .expect("chat should have at least 2 participants");
    let subtext = active_participant.status_message().unwrap_or_default();
    let is_favorite = s.is_favorite(&active_chat);
    let first_image = active_participant.graphics().profile_picture();
    let other_participants_names = build_participants_names(&other_participants);
    let active_media = Some(active_chat.id) == s.chats.active_media;

    // TODO: Pending new message divider implementation
    // let _new_message_text = LOCALES
    //     .lookup(&*APP_LANG.read(), "messages.new")
    //     .unwrap_or_default();

    let platform = match active_participant.platform() {
        warp::multipass::identity::Platform::Desktop => Platform::Desktop,
        warp::multipass::identity::Platform::Mobile => Platform::Mobile,
        _ => Platform::Headless, //TODO: Unknown
    };

    let data = Rc::new(ComposeData {
        active_chat,
        message_groups,
        other_participants,
        active_participant,
        subtext,
        is_favorite,
        first_image,
        other_participants_names,
        active_media,
        platform,
    });

    Some(data)
}

fn get_controls(cx: Scope<ComposeProps>) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let desktop = use_window(cx);
    let data = cx.props.data.clone();
    let active_chat = data.as_ref().map(|x| x.active_chat.clone());
    let active_chat2 = active_chat.clone();
    cx.render(rsx!(
        Button {
            icon: Icon::Heart,
            disabled: data.is_none(),
            aria_label: "Add to Favorites".into(),
            appearance: data
                .as_ref()
                .map(|data| if data.is_favorite {
                    Appearance::Primary
                } else {
                    Appearance::Secondary
                })
                .unwrap_or(Appearance::Secondary),
            tooltip: cx.render(rsx!(Tooltip {
                arrow_position: ArrowPosition::Top,
                text: get_local_text("favorites.add"),
            })),
            onpress: move |_| {
                if let Some(chat) = active_chat.clone() {
                    state.write().mutate(Action::ToggleFavorite(chat));
                }
            }
        },
        Button {
            icon: Icon::PhoneArrowUpRight,
            disabled: data.is_none(),
            aria_label: "Call".into(),
            appearance: Appearance::Secondary,
            tooltip: cx.render(rsx!(Tooltip {
                arrow_position: ArrowPosition::Top,
                text: get_local_text("uplink.call"),
            })),
            onpress: move |_| {
                if let Some(chat) = active_chat2.clone() {
                    state
                        .write_silent()
                        .mutate(Action::ClearPopout(desktop.clone()));
                    state.write_silent().mutate(Action::DisableMedia);
                    state.write().mutate(Action::SetActiveMedia(chat.id));
                }
            }
        },
        Button {
            icon: Icon::VideoCamera,
            disabled: data.is_none(),
            aria_label: "Videocall".into(),
            appearance: Appearance::Secondary,
            tooltip: cx.render(rsx!(Tooltip {
                arrow_position: ArrowPosition::TopRight,
                text: get_local_text("uplink.video-call"),
            })),
        },
    ))
}

fn get_topbar_children(cx: Scope<ComposeProps>) -> Element {
    let data = cx.props.data.clone();
    let is_loading = data.is_none();
    let other_participants_names = data
        .as_ref()
        .map(|x| x.other_participants_names.clone())
        .unwrap_or_default();
    let subtext = data.as_ref().map(|x| x.subtext.clone()).unwrap_or_default();
    cx.render(rsx!(
        if let Some(data) = data {
            if data.other_participants.len() < 2 {rsx! (
                UserImage {
                    loading: false,
                    platform: data.platform,
                    status: convert_status(&data.active_participant.identity_status()),
                    image: data.first_image.clone(),
                }
            )} else {rsx! (
                UserImageGroup {
                    loading: false,
                    participants: build_participants(&data.other_participants),
                }
            )}
        } else {rsx! (
            UserImageGroup {
                loading: true,
                participants: vec![]
            }
        )}
        div {
            class: "user-info",
            if is_loading {
                rsx!(
                    div {
                        class: "skeletal-bars",
                        div {
                            class: "skeletal skeletal-bar",
                        },
                        div {
                            class: "skeletal skeletal-bar",
                        },
                    }
                )
            } else {
                rsx! (
                    p {
                        class: "username",
                        "{other_participants_names}"
                    },
                    p {
                        class: "status",
                        "{subtext}"
                    }
                )
            }
        }
    ))
}

#[allow(clippy::large_enum_variant)]
enum MessagesCommand {
    // contains the emoji reaction
    React((raygun::Message, String)),
    DeleteMessage {
        conv_id: Uuid,
        msg_id: Uuid,
    },
    DownloadAttachment {
        conv_id: Uuid,
        msg_id: Uuid,
        file_name: String,
        directory: String,
    },
}

fn get_messages(cx: Scope<ComposeProps>) -> Element {
    log::trace!("get_messages");
    let state = use_shared_state::<State>(cx)?;
    let user = state.read().account.identity.did_key();

    let script = include_str!("./script.js");
    use_eval(cx)(script.to_string());

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<MessagesCommand>| {
        //to_owned![];
        async move {
            while let Some(cmd) = rx.next().await {
                match cmd {
                    MessagesCommand::React((message, emoji)) => {
                        let warp_cmd_tx = WARP_CMD_CH.tx.clone();
                        let (tx, rx) = futures::channel::oneshot::channel();

                        let mut reactions = message.reactions();
                        reactions.retain(|x| x.users().contains(&user));
                        reactions.retain(|x| x.emoji().eq(&emoji));
                        let reaction_state = if reactions.is_empty() {
                            ReactionState::Add
                        } else {
                            ReactionState::Remove
                        };
                        if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::React {
                            conversation_id: message.conversation_id(),
                            message_id: message.id(),
                            reaction_state,
                            emoji,
                            rsp: tx,
                        })) {
                            log::error!("failed to send warp command: {}", e);
                            continue;
                        }

                        let res = rx.await.expect("command canceled");
                        if res.is_err() {
                            // failed to add/remove reaction
                        }
                    }
                    MessagesCommand::DeleteMessage { conv_id, msg_id } => {
                        let warp_cmd_tx = WARP_CMD_CH.tx.clone();
                        let (tx, rx) = futures::channel::oneshot::channel();
                        if let Err(e) =
                            warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::DeleteMessage {
                                conv_id,
                                msg_id,
                                rsp: tx,
                            }))
                        {
                            log::error!("failed to send warp command: {}", e);
                            continue;
                        }

                        let res = rx.await.expect("command canceled");
                        if let Err(e) = res {
                            log::error!("failed to delete message: {}", e);
                        }
                    }
                    MessagesCommand::DownloadAttachment {
                        conv_id,
                        msg_id,
                        file_name,
                        directory,
                    } => {
                        let warp_cmd_tx = WARP_CMD_CH.tx.clone();
                        let (tx, rx) = futures::channel::oneshot::channel();
                        if let Err(e) =
                            warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::DownloadAttachment {
                                conv_id,
                                msg_id,
                                file_name,
                                directory,
                                rsp: tx,
                            }))
                        {
                            log::error!("failed to send warp command: {}", e);
                            continue;
                        }

                        let res = rx.await.expect("command canceled");
                        match res {
                            Ok(mut stream) => {
                                while let Some(p) = stream.next().await {
                                    log::debug!("{p:?}");
                                }
                            }
                            Err(e) => {
                                log::error!("failed to download attachment: {}", e);
                            }
                        }
                    }
                }
            }
        }
    });

    let data = match &cx.props.data {
        Some(d) => d.clone(),
        None => {
            return cx.render(rsx!(
                div {
                    id: "messages",
                    MessageGroupSkeletal {},
                    MessageGroupSkeletal { alt: true }
                }
            ))
        }
    };

    cx.render(rsx!(
        div {
            id: "messages",
            div {
                data.message_groups.iter().map(|group| {
                    let messages = &group.messages;
                    let active_chat = data.active_chat.clone();
                    let last_message = messages.last().unwrap().message.clone();
                    let sender = state.read().get_friend_identity(&group.sender);
                    let active_language = state.read().settings.language.clone();
                    let platform = match sender.platform() {
                        warp::multipass::identity::Platform::Desktop => Platform::Desktop,
                        warp::multipass::identity::Platform::Mobile => Platform::Mobile,
                        _ => Platform::Headless //TODO: Unknown
                    };
                    let status = convert_status(&sender.identity_status());

                    rsx!(
                        MessageGroup {
                            user_image: cx.render(rsx!(
                                UserImage {
                                    platform: platform,
                                    status: status
                                }
                            )),
                            timestamp: format_timestamp_timeago(last_message.inner.date(), active_language),
                            with_sender: if sender.username().is_empty() { get_local_text("messages.you") } else { sender.username()},
                            remote: group.remote,
                            messages.iter().map(|grouped_message| {
                                let message = grouped_message.message.clone();
                                let message2 = message.clone();
                                let message3 = message.clone();
                                let message4 = message.clone();
                                let reply_message = grouped_message.message.clone();
                                let active_chat = active_chat.clone();
                                let sender_is_self = message.inner.sender() == state.read().account.identity.did_key();

                                // WARNING: these keys are required to prevent a bug with the context menu, which manifests when deleting messages.
                                let context_key = format!("message-{}", message.inner.id());
                                let message_key = message.inner.id().to_string();
                                rsx! (
                                    ContextMenu {
                                        key: "{context_key}",
                                        id: context_key,
                                        items: cx.render(rsx!(
                                            ContextItem {
                                                icon: Icon::ArrowLongLeft,
                                                text: get_local_text("messages.reply"),
                                                onpress: move |_| {
                                                    state.write().mutate(Action::StartReplying(active_chat.clone(), reply_message.inner.clone()));
                                                }
                                            },
                                            ContextItem {
                                                icon: Icon::FaceSmile,
                                                text: get_local_text("messages.react"),
                                                //TODO: let the user pick a reaction
                                                onpress: move |_| {
                                                    // todo: render this by default: ["❤️", "😂", "😍", "💯", "👍", "😮", "😢", "😡", "🤔", "😎"];
                                                    // todo: allow emoji extension instead
                                                    // using "like" for now
                                                    ch.send(MessagesCommand::React((message2.inner.clone(), "👍".into())));
                                                }
                                            },
                                            ContextItem {
                                                icon: Icon::Trash,
                                                danger: true,
                                                text: get_local_text("uplink.delete"),
                                                should_render: sender_is_self,
                                                onpress: move |_| {
                                                    ch.send(MessagesCommand::DeleteMessage { conv_id: message3.inner.conversation_id(), msg_id: message3.inner.id() });
                                                }
                                            },
                                        )),
                                        div {
                                            class: "msg-wrapper",
                                            message.in_reply_to.map(|other_msg| rsx!(
                                            MessageReply {
                                                    key: "reply-{message_key}",
                                                    with_text: other_msg,
                                                    remote: group.remote,
                                                    remote_message: group.remote,
                                                }
                                            )),
                                            Message {
                                                key: "{message_key}",
                                                remote: group.remote,
                                                with_text: message.inner.value().join("\n"),
                                                reactions: message.inner.reactions(),
                                                order: if grouped_message.is_first { Order::First } else if grouped_message.is_last { Order::Last } else { Order::Middle },
                                                attachments: message.inner.attachments(),
                                                on_download: move |file_name| {
                                                    // todo: let the user pick the directory
                                                    ch.send(MessagesCommand::DownloadAttachment {conv_id: message4.inner.conversation_id(), msg_id: message4.inner.id(), file_name, directory: STATIC_ARGS.uplink_path.to_string_lossy().to_string() })
                                                },
                                            },
                                       }
                                    }
                                )
                            })
                        }
                    )
                })
            }
        },
    ))
}

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

fn get_chatbar(cx: Scope<ComposeProps>) -> Element {
    log::trace!("get_chatbar");
    let state = use_shared_state::<State>(cx)?;
    let data = cx.props.data.clone();
    let is_loading = data.is_none();
    let input = use_ref(cx, Vec::<String>::new);
    let should_clear_input = use_state(cx, || false);
    let active_chat_id = data.as_ref().map(|d| d.active_chat.id);

    let is_reply = active_chat_id
        .and_then(|id| {
            state
                .read()
                .chats
                .all
                .get(&id)
                .map(|chat| chat.replying_to.is_some())
        })
        .unwrap_or(false);

    let files_to_upload: &UseState<Vec<PathBuf>> = use_state(cx, Vec::new);

    // used to render the typing indicator
    // for now it doesn't quite work for group messages
    let my_id = state.read().account.identity.did_key();
    let is_typing = active_chat_id
        .and_then(|id| state.read().chats.all.get(&id).cloned())
        .map(|chat| chat.typing_indicator.iter().any(|(id, _)| id != &my_id))
        .unwrap_or_default();

    let msg_ch = use_coroutine(
        cx,
        |mut rx: UnboundedReceiver<(Vec<String>, Uuid, Option<Uuid>)>| {
            to_owned![files_to_upload];
            async move {
                let warp_cmd_tx = WARP_CMD_CH.tx.clone();
                while let Some((msg, conv_id, reply)) = rx.next().await {
                    let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();
                    let cmd = match reply {
                        Some(reply_to) => RayGunCmd::Reply {
                            conv_id,
                            reply_to,
                            msg,
                            rsp: tx,
                        },
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
    use_future(cx, &active_chat_id.clone(), |current_chat| async move {
        loop {
            tokio::time::sleep(Duration::from_secs(STATIC_ARGS.typing_indicator_refresh)).await;
            if let Some(c) = current_chat {
                local_typing_ch1.send(TypingIndicator::Refresh(c));
            }
        }
    });

    let msg_valid =
        |msg: &[String]| !msg.is_empty() && msg.iter().any(|line| !line.trim().is_empty());

    let submit_fn = move || {
        local_typing_ch.send(TypingIndicator::NotTyping);

        let msg = input.read().clone();
        // clearing input here should prevent the possibility to double send a message if enter is pressed twice
        input.write().clear();
        should_clear_input.set(true);

        if !msg_valid(&msg) {
            return;
        }
        let id = match active_chat_id {
            Some(i) => i,
            None => return,
        };

        if STATIC_ARGS.use_mock {
            state.write().mutate(Action::MockSend(id, msg));
        } else {
            let replying_to = state.read().chats.get_replying_to();
            if replying_to.is_some() {
                state.write().mutate(Action::CancelReply(id));
            }
            msg_ch.send((msg, id, replying_to));
        }
    };

    // todo: filter out extensions not meant for this area
    let extensions = &state.read().ui.extensions;
    let _ext_renders: Vec<_> = extensions
        .iter()
        .map(|(_, proxy)| rsx!(proxy.extension.render(cx)))
        .collect();

    let chatbar = cx.render(rsx!(Chatbar {
        loading: is_loading,
        placeholder: get_local_text("messages.say-something-placeholder"),
        reset: should_clear_input.clone(),
        onchange: move |v: String| {
            *input.write_silent() = v.lines().map(|x| x.to_string()).collect::<Vec<String>>();
            if let Some(id) = &active_chat_id {
                local_typing_ch.send(TypingIndicator::Typing(*id));
            }
        },
        onreturn: move |_| submit_fn(),
        controls: cx.render(
            // Load extensions
            //            for node in ext_renders {
            //                rsx!(node)
            //            },
            rsx!(Button {
                icon: Icon::ChevronDoubleRight,
                disabled: is_loading,
                appearance: Appearance::Secondary,
                onpress: move |_| submit_fn(),
                tooltip: cx.render(rsx!(Tooltip {
                    arrow_position: ArrowPosition::Bottom,
                    text: get_local_text("uplink.send"),
                })),
            },)
        ),
        with_replying_to: data
            .map(|data| {
                let active_chat = data.active_chat.clone();
                cx.render(rsx!(active_chat.clone().replying_to.map(|msg| {
                    let our_did = state.read().account.identity.did_key();
                    let mut participants = data.active_chat.participants.clone();
                    participants.retain(|p| p.did_key() == msg.sender());
                    let msg_owner = participants.first();
                    let (platform, status) = get_platform_and_status(msg_owner);

                    rsx!(
                        Reply {
                            label: get_local_text("messages.replying"),
                            remote: our_did != msg.sender(),
                            onclose: move |_| {
                                state.write().mutate(Action::CancelReply(active_chat.id))
                            },
                            message: msg.value().join("\n"),
                            UserImage {
                                platform: platform,
                                status: status,
                            },
                        }
                    )
                })))
            })
            .unwrap_or(None),
        with_file_upload: cx.render(rsx!(Button {
            icon: Icon::Plus,
            disabled: is_loading || is_reply,
            appearance: Appearance::Primary,
            onpress: move |_| {
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
                }
            },
            tooltip: cx.render(rsx!(Tooltip {
                arrow_position: ArrowPosition::Bottom,
                text: get_local_text("files.upload"),
            }))
        }))
    }));

    let platform = Platform::Headless;
    let status = Status::Online;

    cx.render(rsx!(
        is_typing.then(|| {
            rsx!(MessageTyping {
                user_image: cx.render(rsx!(
                    UserImage {
                        platform: platform,
                        status: status
                    }
                ))
            })
        })
        chatbar,
        Attachments {files: files_to_upload.clone()}
    ))
}

#[derive(Props, PartialEq)]
pub struct AttachmentProps {
    files: UseState<Vec<PathBuf>>,
}

#[allow(non_snake_case)]
fn Attachments(cx: Scope<AttachmentProps>) -> Element {
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
                button_icon: Icon::Trash,
                on_press: move |_| {
                    cx.props.files.with_mut(|files| {
                        files.retain(|x| {
                            let s = x.to_string_lossy().to_string();
                            s != file_name
                        })
                    });
                },
            })
        })));

    cx.render(rsx!(div {
        id: "compose-attachments",
        attachments
    }))
}

fn get_platform_and_status(msg_sender: Option<&Identity>) -> (Platform, Status) {
    let sender = match msg_sender {
        Some(identity) => identity,
        None => return (Platform::Desktop, Status::Offline),
    };
    let user_sender = build_user_from_identity(sender.clone());
    (user_sender.platform, user_sender.status)
}
