use std::{
    ffi::OsStr,
    path::PathBuf,
    rc::Rc,
    time::{Duration, Instant},
};

use dioxus::prelude::{EventHandler, *};

use dioxus_router::use_router;
use futures::{channel::oneshot, StreamExt};

use kit::{
    components::{
        context_menu::{ContextItem, ContextMenu, IdentityHeader},
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
        input::Input,
        tooltip::{ArrowPosition, Tooltip},
        Appearance,
    },
    layout::{
        chatbar::{Chatbar, Reply},
        topbar::Topbar,
    },
};

use common::{
    icons::outline::Shape as Icon,
    state::{group_messages, GroupedMessage, MessageGroup},
    warp_runner::{
        ui_adapter::{self},
        MultiPassCmd,
    },
};
use common::{
    state::{ui, Action, Chat, Identity, State},
    warp_runner::{RayGunCmd, WarpCmd},
    STATIC_ARGS, WARP_CMD_CH,
};

use common::language::get_local_text;
use dioxus_desktop::{use_eval, use_window, DesktopContext};
use rfd::FileDialog;
#[cfg(target_os = "windows")]
use tokio::time::sleep;
use uuid::Uuid;
use warp::{
    crypto::DID,
    logging::tracing::log,
    multipass::identity::{self, IdentityStatus},
    raygun::{self, ConversationType, ReactionState},
};
use wry::webview::FileDropEvent;

use crate::{
    components::media::player::MediaPlayer,
    layouts::storage::{
        decoded_pathbufs, get_drag_event, verify_if_there_are_valid_paths, ANIMATION_DASH_SCRIPT,
        FEEDBACK_TEXT_SCRIPT,
    },
    utils::{
        build_participants, build_user_from_identity, format_timestamp::format_timestamp_timeago,
    },
    UPLINK_ROUTES,
};

pub const SELECT_CHAT_BAR: &str = r#"
    var chatBar = document.getElementsByClassName('chatbar')[0].getElementsByClassName('input_textarea')[0]
    chatBar.focus()
"#;

const SETUP_CONTEXT_PARENT: &str = r#"
    const right_clickable = document.getElementsByClassName("has-context-handler")
    console.log("E", right_clickable)
    for (var i = 0; i < right_clickable.length; i++) {
        //Disable default right click actions (opening the inspect element dropdown)
        right_clickable.item(i).addEventListener("contextmenu",
        function (ev) {
        ev.preventDefault()
        })
    }
"#;

struct ComposeData {
    active_chat: Chat,
    my_id: Identity,
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
    upload_files: Option<UseState<Vec<PathBuf>>>,
}

#[allow(non_snake_case)]
pub fn Compose(cx: Scope) -> Element {
    log::trace!("rendering compose");
    let state = use_shared_state::<State>(cx)?;
    let data = get_compose_data(cx);
    let data2 = data.clone();
    let drag_event: &UseRef<Option<FileDropEvent>> = use_ref(cx, || None);
    let window = use_window(cx);
    let overlay_script = include_str!("./overlay.js");

    let files_to_upload = use_state(cx, Vec::new);

    state.write_silent().ui.current_layout = ui::Layout::Compose;
    if state.read().chats().active_chat_has_unreads() {
        state.write().mutate(Action::ClearActiveUnreads);
    }
    #[cfg(target_os = "windows")]
    use_future(cx, (), |_| {
        to_owned![files_to_upload, overlay_script, window, drag_event];
        async move {
            // ondragover function from div does not work on windows
            loop {
                sleep(Duration::from_millis(100)).await;
                if let FileDropEvent::Hovered(_) = get_drag_event() {
                    let new_files =
                        drag_and_drop_function(&window, &drag_event, overlay_script.clone()).await;
                    let mut new_files_to_upload: Vec<_> = files_to_upload
                        .current()
                        .iter()
                        .filter(|file_name| !new_files.contains(file_name))
                        .cloned()
                        .collect();
                    new_files_to_upload.extend(new_files);
                    files_to_upload.set(new_files_to_upload);
                }
            }
        }
    });

    cx.render(rsx!(
        div {
            id: "compose",
            ondragover: move |_| {
                if drag_event.with(|i| i.clone()).is_none() {
                    cx.spawn({
                        to_owned![files_to_upload, drag_event, window, overlay_script];
                        async move {
                           let new_files = drag_and_drop_function(&window, &drag_event, overlay_script).await;
                            let mut new_files_to_upload: Vec<_> = files_to_upload
                                .current()
                                .iter()
                                .filter(|file_name| !new_files.contains(file_name))
                                .cloned()
                                .collect();
                            new_files_to_upload.extend(new_files);
                            files_to_upload.set(new_files_to_upload);
                        }
                    });
                }
            },
            div {
                id: "overlay-element",
                class: "overlay-element",
                div {id: "dash-element", class: "dash-background active-animation"},
                p {id: "overlay-text0", class: "overlay-text"},
                p {id: "overlay-text", class: "overlay-text"}
            },
            Topbar {
                with_back_button: state.read().ui.is_minimal_view() || state.read().ui.sidebar_hidden,
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
            match data.as_ref() {
                None => rsx!(
                    div {
                        id: "messages",
                        MessageGroupSkeletal {},
                        MessageGroupSkeletal { alt: true }
                    }
                ),
                Some(data) =>  rsx!(get_messages{data: data.clone()}),
            },
            get_chatbar {
                data: data,
                upload_files: files_to_upload.clone()
            }
        }
    ))
}

fn get_compose_data(cx: Scope) -> Option<Rc<ComposeData>> {
    let state = use_shared_state::<State>(cx)?;
    let s = state.read();
    // the Compose page shouldn't be called before chats is initialized. but check here anyway.
    if !s.chats().initialized {
        return None;
    }

    let active_chat = match s.get_active_chat() {
        Some(c) => c,
        None => return None,
    };
    let participants = s.chat_participants(&active_chat);
    // warning: if a friend changes their username, if state.friends is updated, the old username would still be in state.chats
    // this would be "fixed" the next time uplink starts up
    let other_participants: Vec<Identity> = s.remove_self(&participants);
    let active_participant = other_participants
        .first()
        .cloned()
        .expect("chat should have at least 2 participants");

    let subtext = match active_chat.conversation_type {
        ConversationType::Direct => active_participant.status_message().unwrap_or_default(),
        _ => String::new(),
    };
    let is_favorite = s.is_favorite(&active_chat);

    let first_image = active_participant.profile_picture();
    let other_participants_names = State::join_usernames(&other_participants);
    let active_media = Some(active_chat.id) == s.chats().active_media;

    // TODO: Pending new message divider implementation
    // let _new_message_text = LOCALES
    //     .lookup(&*APP_LANG.read(), "messages.new")
    //     .unwrap_or_default();

    let platform = active_participant.platform().into();

    let data = Rc::new(ComposeData {
        active_chat,
        other_participants,
        my_id: s.get_own_identity(),
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
    let data = &cx.props.data;
    let active_chat = data.as_ref().map(|x| &x.active_chat);
    let favorite = data.as_ref().map(|d| d.is_favorite).unwrap_or_default();
    cx.render(rsx!(
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
        Button {
            icon: Icon::PhoneArrowUpRight,
            disabled: true,
            aria_label: "Call".into(),
            appearance: Appearance::Secondary,
            tooltip: cx.render(rsx!(Tooltip {
                arrow_position: ArrowPosition::Top,
                text: get_local_text("uplink.coming-soon")
            })),
            onpress: move |_| {
                if let Some(chat) = active_chat.as_ref() {
                    state
                        .write_silent()
                        .mutate(Action::ClearCallPopout(desktop.clone()));
                    state.write_silent().mutate(Action::DisableMedia);
                    state.write().mutate(Action::SetActiveMedia(chat.id));
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

fn get_topbar_children(cx: Scope<ComposeProps>) -> Element {
    let data = cx.props.data.clone();

    let data = match data {
        Some(d) => d,
        None => {
            return cx.render(rsx!(
                UserImageGroup {
                    loading: true,
                    participants: vec![]
                },
                div {
                    class: "user-info",
                    aria_label: "user-info",
                    div {
                        class: "skeletal-bars",
                        div {
                            class: "skeletal skeletal-bar",
                        },
                        div {
                            class: "skeletal skeletal-bar",
                        },
                    }
                }
            ))
        }
    };

    let conversation_title = match data.active_chat.conversation_name.as_ref() {
        Some(n) => n.clone(),
        None => data.other_participants_names.clone(),
    };
    let subtext = data.subtext.clone();

    cx.render(rsx!(
        if data.active_chat.conversation_type == ConversationType::Direct {rsx! (
            UserImage {
                loading: false,
                platform: data.platform,
                status: data.active_participant.identity_status().into(),
                image: data.first_image.clone(),
            }
        )} else {rsx! (
            UserImageGroup {
                loading: false,
                participants: build_participants(&data.other_participants),
            }
        )}
        div {
            class: "user-info",
            aria_label: "user-info",
            p {
                class: "username",
                "{conversation_title}"
            },
            p {
                class: "status",
                "{subtext}"
            }
        }
    ))
}

#[allow(clippy::large_enum_variant)]
enum MessagesCommand {
    // contains the emoji reaction
    // conv id, msg id, emoji
    React((raygun::Message, String)),
    DeleteMessage {
        conv_id: Uuid,
        msg_id: Uuid,
    },
    DownloadAttachment {
        conv_id: Uuid,
        msg_id: Uuid,
        file_name: String,
        file_path_to_download: PathBuf,
    },
    EditMessage {
        conv_id: Uuid,
        msg_id: Uuid,
        msg: Vec<String>,
    },
    FetchMore {
        conv_id: Uuid,
        new_len: usize,
        current_len: usize,
    },
}

/// Lazy loading scheme:
/// load DEFAULT_NUM_TO_TAKE messages to start.
/// tell group_messages to flag the first X messages.
/// if onmouseout triggers over any of those messages, load Y more.
const DEFAULT_NUM_TO_TAKE: usize = 20;
#[inline_props]
fn get_messages(cx: Scope, data: Rc<ComposeData>) -> Element {
    log::trace!("get_messages");
    let user = data.my_id.did_key();
    let state = use_shared_state::<State>(cx)?;

    let num_to_take = use_state(cx, || DEFAULT_NUM_TO_TAKE);
    let prev_chat_id = use_ref(cx, || data.active_chat.id);
    let newely_fetched_messages: &UseRef<Option<(Uuid, Vec<ui_adapter::Message>)>> =
        use_ref(cx, || None);

    let quick_profile_uuid = &*cx.use_hook(|| Uuid::new_v4().to_string());
    let identity_profile = use_state(cx, || Identity::default());
    let update_script = use_state(cx, || String::new());

    if let Some((id, m)) = newely_fetched_messages.write_silent().take() {
        if m.is_empty() {
            log::debug!("finished loading chat: {id}");
            state.write().finished_loading_chat(id);
        } else {
            num_to_take.with_mut(|x| *x = x.saturating_add(m.len()));
            state.write().prepend_messages_to_chat(id, m);
        }
    }

    // this needs to be a hook so it can change inside of the use_future.
    // it could be passed in as a dependency but then the wait would reset every time a message comes in.
    let max_to_take = use_ref(cx, || data.active_chat.messages.len());
    if *max_to_take.read() != data.active_chat.messages.len() {
        *max_to_take.write_silent() = data.active_chat.messages.len();
    }

    // don't scroll to the bottom again if new messages come in while the user is scrolling up. only scroll
    // to the bottom when the user selects the active chat
    // also must reset num_to_take when the active_chat changes
    let active_chat = use_ref(cx, || None);
    let currently_active = Some(data.active_chat.id);
    let eval = use_eval(cx);
    if *active_chat.read() != currently_active {
        *active_chat.write_silent() = currently_active;
        num_to_take.set(DEFAULT_NUM_TO_TAKE);
    }

    use_effect(cx, &data.active_chat.id, |id| {
        to_owned![eval, prev_chat_id];
        async move {
            // yes, this check seems like some nonsense. but it eliminates a jitter and if
            // switching out of the chats view ever gets fixed, it would let you scroll up in the active chat,
            // switch to settings or whatnot, then come back to the chats view and not lose your place.
            if *prev_chat_id.read() != id {
                *prev_chat_id.write_silent() = id;
                let script = include_str!("./script.js");
                eval(script.to_string());
            }
            eval(SETUP_CONTEXT_PARENT.to_string());
        }
    });

    let _ch = use_coroutine(cx, |mut rx: UnboundedReceiver<MessagesCommand>| {
        to_owned![newely_fetched_messages];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(cmd) = rx.next().await {
                match cmd {
                    MessagesCommand::React((message, emoji)) => {
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
                        file_path_to_download,
                    } => {
                        let (tx, rx) = futures::channel::oneshot::channel();
                        if let Err(e) =
                            warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::DownloadAttachment {
                                conv_id,
                                msg_id,
                                file_name,
                                file_path_to_download,
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
                    MessagesCommand::EditMessage {
                        conv_id,
                        msg_id,
                        msg,
                    } => {
                        let (tx, rx) = futures::channel::oneshot::channel();
                        if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::EditMessage {
                            conv_id,
                            msg_id,
                            msg,
                            rsp: tx,
                        })) {
                            log::error!("failed to send warp command: {}", e);
                            continue;
                        }

                        let res = rx.await.expect("command canceled");
                        if let Err(e) = res {
                            log::error!("failed to edit message: {}", e);
                        }
                    }
                    MessagesCommand::FetchMore {
                        conv_id,
                        new_len,
                        current_len,
                    } => {
                        let (tx, rx) = futures::channel::oneshot::channel();
                        if let Err(e) =
                            warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::FetchMessages {
                                conv_id,
                                new_len,
                                current_len,
                                rsp: tx,
                            }))
                        {
                            log::error!("failed to send warp command: {}", e);
                            continue;
                        }

                        match rx.await.expect("command canceled") {
                            Ok(m) => {
                                newely_fetched_messages.set(Some((conv_id, m)));
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

    cx.render(rsx!(
        div {
            id: "messages",
            div {
                rsx!(render_message_groups{
                    groups: group_messages(data.my_id.did_key(), *num_to_take.get(), DEFAULT_NUM_TO_TAKE,  &data.active_chat.messages),
                    active_chat_id: data.active_chat.id,
                    num_messages_in_conversation: data.active_chat.messages.len(),
                    num_to_take: num_to_take.clone(),
                    has_more: data.active_chat.has_more_messages,
                    on_context_menu_action: move |(e, id): (Event<MouseData>, Identity)| {
                        if !identity_profile.get().eq(&id) {
                            let id = if state.read().get_own_identity().did_key().eq(&id.did_key()) {
                                let mut id = id;
                                id.set_identity_status(IdentityStatus::Online);
                                id
                            } else {
                                id
                            };
                            identity_profile.set(id);
                        }
                        //Dont think there is any way of manually moving elements via dioxus
                        let script = include_str!("./show_context.js")
                            .replace("UUID", quick_profile_uuid)
                            .replace("$PAGE_X", &e.page_coordinates().x.to_string())
                            .replace("$PAGE_Y", &e.page_coordinates().y.to_string());
                        update_script.set(script);
                    }
                })
            }
        },
        QuickProfileContext{
            id: quick_profile_uuid,
            update_script: update_script,
            identity: identity_profile
        }
    ))
}

#[derive(Props)]
struct AllMessageGroupsProps<'a> {
    groups: Vec<MessageGroup<'a>>,
    active_chat_id: Uuid,
    num_messages_in_conversation: usize,
    num_to_take: UseState<usize>,
    has_more: bool,
    on_context_menu_action: EventHandler<'a, (Event<MouseData>, Identity)>,
}

// attempting to move the contents of this function into the above rsx! macro causes an error: cannot return vale referencing
// temporary location
fn render_message_groups<'a>(cx: Scope<'a, AllMessageGroupsProps<'a>>) -> Element<'a> {
    log::trace!("render message groups");
    cx.render(rsx!(cx.props.groups.iter().map(|_group| {
        rsx!(render_message_group {
            group: _group,
            active_chat_id: cx.props.active_chat_id,
            num_messages_in_conversation: cx.props.num_messages_in_conversation,
            num_to_take: cx.props.num_to_take.clone(),
            has_more: cx.props.has_more,
            on_context_menu_action: move |e| cx.props.on_context_menu_action.call(e)
        })
    })))
}

#[derive(Props)]
struct MessageGroupProps<'a> {
    group: &'a MessageGroup<'a>,
    active_chat_id: Uuid,
    num_messages_in_conversation: usize,
    num_to_take: UseState<usize>,
    has_more: bool,
    on_context_menu_action: EventHandler<'a, (Event<MouseData>, Identity)>,
}

fn render_message_group<'a>(cx: Scope<'a, MessageGroupProps<'a>>) -> Element<'a> {
    let state = use_shared_state::<State>(cx)?;

    let MessageGroupProps {
        group,
        active_chat_id: _,
        num_messages_in_conversation: _,
        num_to_take: _,
        has_more: _,
        on_context_menu_action: _,
    } = cx.props;

    let messages = &group.messages;
    let last_message = messages.last().unwrap().message;
    let sender = state.read().get_identity(&group.sender);
    let sender_clone = sender.clone();
    let sender_clone_2 = sender.clone();
    let sender_name = if sender.username().is_empty() {
        get_local_text("messages.you")
    } else {
        sender.username()
    };
    let active_language = &state.read().settings.language;

    let mut sender_status = sender.identity_status().into();
    if !group.remote && sender_status == Status::Offline {
        sender_status = Status::Online;
    }

    cx.render(rsx!(MessageGroup {
        user_image: cx.render(rsx!(UserImage {
            image: sender.profile_picture(),
            platform: sender.platform().into(),
            status: sender_status,
            on_press: move |e| {
                cx.props.on_context_menu_action.call((e, sender.to_owned()));
            }
            oncontextmenu: move |e| {
                cx.props.on_context_menu_action.call((e, sender_clone.to_owned()));
            }
        })),
        timestamp: format_timestamp_timeago(last_message.inner.date(), active_language),
        sender: sender_name.clone(),
        with_sender: {
            let sender_clone_3 = sender_clone_2.clone();
            cx.render(rsx!(
                div {
                    onclick: move |e| {
                        cx.props.on_context_menu_action.call((e, sender_clone_2.to_owned()));
                    },
                    oncontextmenu: move |e| {
                        cx.props.on_context_menu_action.call((e, sender_clone_3.to_owned()));
                    },
                    p {
                        class: "sender pressable has-context-handler",
                        aria_label: "sender_name",
                        "{sender_name}",
                    }
                }
            ))
        },
        remote: group.remote,
        children: cx.render(rsx!(render_messages {
            messages: &group.messages,
            active_chat_id: cx.props.active_chat_id,
            is_remote: group.remote,
            has_more: cx.props.has_more,
            num_messages_in_conversation: cx.props.num_messages_in_conversation,
            num_to_take: cx.props.num_to_take.clone(),
        }))
    },))
}

#[derive(Props)]
struct MessagesProps<'a> {
    messages: &'a Vec<GroupedMessage<'a>>,
    active_chat_id: Uuid,
    num_messages_in_conversation: usize,
    num_to_take: UseState<usize>,
    is_remote: bool,
    has_more: bool,
}
fn render_messages<'a>(cx: Scope<'a, MessagesProps<'a>>) -> Element<'a> {
    let state = use_shared_state::<State>(cx)?;
    let edit_msg: &UseState<Option<Uuid>> = use_state(cx, || None);

    let ch = use_coroutine_handle::<MessagesCommand>(cx)?;

    cx.render(rsx!(cx.props.messages.iter().map(|grouped_message| {
        let should_fetch_more = grouped_message.should_fetch_more;
        let message = &grouped_message.message;
        let sender_is_self = message.inner.sender() == state.read().did_key();

        // WARNING: these keys are required to prevent a bug with the context menu, which manifests when deleting messages.
        let is_editing = edit_msg
            .get()
            .map(|id| !cx.props.is_remote && (id == message.inner.id()))
            .unwrap_or(false);
        let context_key = format!("message-{}-{}", &message.key, is_editing);
        let _message_key = format!("{}-{:?}", &message.key, is_editing);
        let msg_uuid = message.inner.id();

        rsx!(ContextMenu {
            key: "{context_key}",
            id: context_key,
            on_mouseenter: move |_| {
                if should_fetch_more {
                    let new_num_to_take = cx
                        .props
                        .num_to_take
                        .get()
                        .saturating_add(DEFAULT_NUM_TO_TAKE * 2);
                    // lazily render
                    if new_num_to_take < cx.props.num_messages_in_conversation {
                        cx.props.num_to_take.set(new_num_to_take);
                    } else if cx.props.has_more {
                        // lazily add more messages to conversation, then render
                        ch.send(MessagesCommand::FetchMore {
                            conv_id: cx.props.active_chat_id,
                            new_len: new_num_to_take,
                            current_len: cx.props.num_messages_in_conversation,
                        })
                    }
                }
            },
            children: cx.render(rsx!(render_message {
                message: grouped_message,
                is_remote: cx.props.is_remote,
                message_key: _message_key,
                edit_msg: edit_msg.clone(),
            })),
            items: cx.render(rsx!(
                ContextItem {
                    icon: Icon::ArrowLongLeft,
                    text: get_local_text("messages.reply"),
                    onpress: move |_| {
                        state
                            .write()
                            .mutate(Action::StartReplying(&cx.props.active_chat_id, message));
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
                        ch.send(MessagesCommand::React((message.inner.clone(), "👍".into())));
                    }
                },
                ContextItem {
                    icon: Icon::Pencil,
                    text: get_local_text("messages.edit"),
                    should_render: !cx.props.is_remote
                        && edit_msg.get().map(|id| id != msg_uuid).unwrap_or(true),
                    onpress: move |_| {
                        edit_msg.set(Some(msg_uuid));
                        log::debug!("editing msg {msg_uuid}");
                    }
                },
                ContextItem {
                    icon: Icon::Pencil,
                    text: get_local_text("messages.cancel-edit"),
                    should_render: !cx.props.is_remote
                        && edit_msg.get().map(|id| id == msg_uuid).unwrap_or(false),
                    onpress: move |_| {
                        edit_msg.set(None);
                    }
                },
                ContextItem {
                    icon: Icon::Trash,
                    danger: true,
                    text: get_local_text("uplink.delete"),
                    should_render: sender_is_self,
                    onpress: move |_| {
                        ch.send(MessagesCommand::DeleteMessage {
                            conv_id: message.inner.conversation_id(),
                            msg_id: message.inner.id(),
                        });
                    }
                },
            )) // end of context menu items
        }) // end context menu
    }))) // end outer cx.render
}

#[derive(Props)]
struct MessageProps<'a> {
    message: &'a GroupedMessage<'a>,
    is_remote: bool,
    message_key: String,
    edit_msg: UseState<Option<Uuid>>,
}
fn render_message<'a>(cx: Scope<'a, MessageProps<'a>>) -> Element<'a> {
    //log::trace!("render message {}", &cx.props.message.message.key);
    let ch = use_coroutine_handle::<MessagesCommand>(cx)?;

    let MessageProps {
        message,
        is_remote: _,
        message_key,
        edit_msg,
    } = cx.props;
    let grouped_message = message;
    let message = grouped_message.message;
    let is_editing = edit_msg
        .get()
        .map(|id| !cx.props.is_remote && (id == message.inner.id()))
        .unwrap_or(false);

    cx.render(rsx!(
        div {
            class: "msg-wrapper",
            message.in_reply_to.as_ref().map(|other_msg| rsx!(
            MessageReply {
                    key: "reply-{message_key}",
                    with_text: other_msg.to_string(),
                    remote: cx.props.is_remote,
                    remote_message: cx.props.is_remote,
                }
            )),
            Message {
                id: message_key.clone(),
                key: "{message_key}",
                editing: is_editing,
                remote: cx.props.is_remote,
                with_text: message.inner.value().join("\n"),
                reactions: message.inner.reactions(),
                order: if grouped_message.is_first { Order::First } else if grouped_message.is_last { Order::Last } else { Order::Middle },
                attachments: message.inner.attachments(),
                on_download: move |file_name| {
                    let file_extension = std::path::Path::new(&file_name)
                        .extension()
                        .and_then(OsStr::to_str)
                        .map(|s| s.to_string())
                        .unwrap_or_default();
                    let file_stem = PathBuf::from(&file_name)
                        .file_stem()
                        .and_then(OsStr::to_str)
                        .map(str::to_string)
                        .unwrap_or_default();
                    if let Some(file_path_to_download) = FileDialog::new()
                    .set_directory(dirs::download_dir().unwrap_or_default()).set_file_name(&file_stem).add_filter("", &[&file_extension]).save_file() {
                        ch.send(MessagesCommand::DownloadAttachment {
                            conv_id: message.inner.conversation_id(),
                            msg_id: message.inner.id(),
                            file_name, file_path_to_download
                        })
                    }
                },
                on_edit: move |update: String| {
                    edit_msg.set(None);
                    let msg = update.split('\n').collect::<Vec<_>>();
                    let is_valid = msg.iter().any(|x| !x.trim().is_empty());
                    let msg = msg.iter().map(|x| x.to_string()).collect();
                    if message.inner.value() == msg {
                        return;
                    }
                    if !is_valid {
                        ch.send(MessagesCommand::DeleteMessage { conv_id: message.inner.conversation_id(), msg_id: message.inner.id() });
                    }
                    else {
                        ch.send(MessagesCommand::EditMessage { conv_id: message.inner.conversation_id(), msg_id: message.inner.id(), msg})
                    }
                }
            },
        }
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

// todo: display loading indicator if sending a message that takes a long time to upload attachments
fn get_chatbar<'a>(cx: &'a Scoped<'a, ComposeProps>) -> Element<'a> {
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
        tooltip: get_local_text("messages.not-friends"),
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
            icon: Icon::ChevronDoubleRight,
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
            icon: Icon::Plus,
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
                button_icon: Icon::Trash,
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

// Like ui::src:layout::storage::drag_and_drop_function
async fn drag_and_drop_function(
    window: &DesktopContext,
    drag_event: &UseRef<Option<FileDropEvent>>,
    overlay_script: String,
) -> Vec<PathBuf> {
    *drag_event.write_silent() = Some(get_drag_event());
    let mut new_files_to_upload = Vec::new();
    loop {
        let file_drop_event = get_drag_event();
        match file_drop_event {
            FileDropEvent::Hovered(files_local_path) => {
                if verify_if_there_are_valid_paths(&files_local_path) {
                    let mut script = overlay_script.replace("$IS_DRAGGING", "true");
                    if files_local_path.len() > 1 {
                        script.push_str(&FEEDBACK_TEXT_SCRIPT.replace(
                            "$TEXT",
                            &format!(
                                "{} {}!",
                                files_local_path.len(),
                                get_local_text("files.files-to-upload")
                            ),
                        ));
                    } else {
                        script.push_str(&FEEDBACK_TEXT_SCRIPT.replace(
                            "$TEXT",
                            &format!(
                                "{} {}!",
                                files_local_path.len(),
                                get_local_text("files.one-file-to-upload")
                            ),
                        ));
                    }
                    window.eval(&script);
                }
            }
            FileDropEvent::Dropped(files_local_path) => {
                if verify_if_there_are_valid_paths(&files_local_path) {
                    *drag_event.write_silent() = None;
                    new_files_to_upload = decoded_pathbufs(files_local_path);
                    let mut script = overlay_script.replace("$IS_DRAGGING", "false");
                    script.push_str(ANIMATION_DASH_SCRIPT);
                    script.push_str(SELECT_CHAT_BAR);
                    window.set_focus();
                    window.eval(&script);
                    break;
                }
            }
            _ => {
                *drag_event.write_silent() = None;
                let script = overlay_script.replace("$IS_DRAGGING", "false");
                window.eval(&script);
                break;
            }
        };
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    *drag_event.write_silent() = None;
    new_files_to_upload
}

#[derive(Props)]
pub struct QuickProfileProps<'a> {
    id: &'a String,
    identity: &'a UseState<Identity>,
    update_script: &'a UseState<String>,
    children: Element<'a>,
}

enum QuickProfileCmd {
    CreateConversation(Option<Chat>, DID),
    RemoveFriend(DID),
    BlockFriend(DID),
    RemoveDirectConvs(DID),
    Chat(Option<Chat>, String),
}

// Create a quick profile context menu
#[allow(non_snake_case)]
pub fn QuickProfileContext<'a>(cx: Scope<'a, QuickProfileProps<'a>>) -> Element<'a> {
    let state = use_shared_state::<State>(cx)?;
    let id = cx.props.id;

    let identity = cx.props.identity.get();
    let remove_identity = identity.clone();
    let block_identity = identity.clone();

    let did = &identity.did_key();
    let chat_of = state.read().get_chat_with_friend(identity.did_key());
    let chat_send = chat_of.clone();

    let chat_is_current = match state.read().get_active_chat() {
        Some(c) => match &chat_of {
            Some(cO) => c.eq(&cO),
            None => false,
        },
        None => false,
    };

    let eval = use_eval(cx);
    use_future(cx, cx.props.update_script, |update_script| {
        to_owned![eval];
        async move {
            let script = update_script.get();
            if !script.is_empty() {
                eval(script.to_string());
            }
        }
    });

    let is_self = state.read().get_own_identity().did_key().eq(did);
    let is_friend = state.read().has_friend_with_did(did);

    let router = use_router(cx);

    let chat_with: &UseState<Option<Uuid>> = use_state(cx, || None);
    if let Some(id) = *chat_with.get() {
        chat_with.set(None);
        state.write().mutate(Action::ChatWith(&id, true));
        if state.read().ui.is_minimal_view() {
            state.write().mutate(Action::SidebarHidden(true));
        }
        router.replace_route(UPLINK_ROUTES.chat, None, None);
    }

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<QuickProfileCmd>| {
        to_owned![chat_with];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(cmd) = rx.next().await {
                match cmd {
                    QuickProfileCmd::CreateConversation(chat, did) => {
                        // verify chat exists
                        let chat = match chat {
                            Some(c) => c.id,
                            None => {
                                // if not, create the chat
                                let (tx, rx) = oneshot::channel();
                                if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(
                                    RayGunCmd::CreateConversation {
                                        recipient: did,
                                        rsp: tx,
                                    },
                                )) {
                                    log::error!("failed to send warp command: {}", e);
                                    continue;
                                }

                                let rsp = rx.await.expect("command canceled");

                                match rsp {
                                    Ok(c) => c,
                                    Err(e) => {
                                        log::error!("failed to create conversation: {}", e);
                                        continue;
                                    }
                                }
                            }
                        };
                        chat_with.set(Some(chat));
                    }
                    QuickProfileCmd::RemoveFriend(did) => {
                        let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();
                        if let Err(e) =
                            warp_cmd_tx.send(WarpCmd::MultiPass(MultiPassCmd::RemoveFriend {
                                did,
                                rsp: tx,
                            }))
                        {
                            log::error!("failed to send warp command: {}", e);
                            continue;
                        }

                        let rsp = rx.await.expect("command canceled");
                        if let Err(e) = rsp {
                            log::error!("failed to remove friend: {}", e);
                        }
                    }
                    QuickProfileCmd::BlockFriend(did) => {
                        let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();
                        if let Err(e) = warp_cmd_tx
                            .send(WarpCmd::MultiPass(MultiPassCmd::Block { did, rsp: tx }))
                        {
                            log::error!("failed to send warp command: {}", e);
                            continue;
                        }

                        let rsp = rx.await.expect("command canceled");
                        if let Err(e) = rsp {
                            // todo: display message to user
                            log::error!("failed to block friend: {}", e);
                        }
                    }
                    QuickProfileCmd::RemoveDirectConvs(recipient) => {
                        let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();
                        if let Err(e) =
                            warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::RemoveDirectConvs {
                                recipient: recipient.clone(),
                                rsp: tx,
                            }))
                        {
                            log::error!("failed to send warp command: {}", e);
                            continue;
                        }

                        let rsp = rx.await.expect("command canceled");
                        if let Err(e) = rsp {
                            log::error!(
                                "failed to remove conversation with friend {}: {}",
                                recipient,
                                e
                            );
                        }
                    }
                    QuickProfileCmd::Chat(chat, msg) => {
                        let c = match chat {
                            Some(c) => c.id,
                            None => return,
                        };
                        let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();
                        let cmd = RayGunCmd::SendMessage {
                            conv_id: c,
                            msg: vec![msg],
                            attachments: Vec::new(),
                            rsp: tx,
                        };
                        if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(cmd)) {
                            log::error!("failed to send warp command: {}", e);
                            continue;
                        }

                        let rsp = rx.await.expect("command canceled");
                        if let Err(e) = rsp {
                            log::error!("failed to send message: {}", e);
                        }
                        chat_with.set(Some(c));
                    }
                }
            }
        }
    });

    cx.render(rsx!(ContextMenu {
        id: format!("{id}"),
        items: cx.render(rsx!(
            IdentityHeader {
                identity: identity
            },
            hr{},
            div {
                id: "profile-name",
                aria_label: "Context Menu",
                p {
                    class: "text",
                    aria_label: "message-text",
                    "{cx.props.identity.username()}"
                }
            }
            identity.status_message().and_then(|s|{
                cx.render(rsx!(            
                    hr{},
                    div {
                        id: "profile-status",
                        aria_label: "Context Menu",
                        p {
                            class: "text bold",
                            aria_label: "message-text",
                            get_local_text("uplink.status")
                        },
                        hr {},
                        p {
                            class: "text",
                            aria_label: "message-text",
                            s
                        }
                    }
                ))
            }),
            hr{},
            if is_self {
                rsx!(ContextItem {
                    icon: Icon::UserCircle,
                    text: get_local_text("quickprofile.self-edit"),
                    onpress: move |_| {
                        router.replace_route(UPLINK_ROUTES.settings, None, None);
                    }
                })
            } else {
                rsx!(
                    /*ContextItem {
                    icon: Icon::UserCircle,
                    text: get_local_text("quickprofile.profile"),
                    // TODO: Show a profile popup
                },*/
                if is_friend {
                    rsx!(
                        if !chat_is_current {
                            rsx!(
                                ContextItem {
                                icon: Icon::ChatBubbleBottomCenterText,
                                text: get_local_text("quickprofile.message"),
                                onpress: move |_| {
                                    ch.send(QuickProfileCmd::CreateConversation(chat_of.clone(), identity.did_key()));
                                }
                            })
                        }
                        /*ContextItem {
                            icon: Icon::PhoneArrowUpRight,
                            text: get_local_text("quickprofile.call"),
                            // TODO: Impl missing
                        }*/
                    )
                }
                hr{},
                if is_friend {
                    rsx!(ContextItem {
                        icon: Icon::UserMinus,
                        text: get_local_text("quickprofile.friend-remove"),
                        onpress: move |_| {
                            ch.send(QuickProfileCmd::RemoveFriend(remove_identity.did_key()));
                            ch.send(QuickProfileCmd::RemoveDirectConvs(remove_identity.did_key()));
                        }
                    })
                }
                ContextItem {
                    icon: Icon::UserBlock,
                    text: get_local_text("quickprofile.block"),
                    onpress: move |_| {
                        ch.send(QuickProfileCmd::BlockFriend(block_identity.did_key()));
                        ch.send(QuickProfileCmd::RemoveDirectConvs(block_identity.did_key()));
                    }
                },
                if is_friend && !chat_is_current {
                    rsx!(
                        hr{},
                        Input {
                            placeholder: get_local_text("quickprofile.chat-placeholder"),
                            onreturn: move |(val, _,_)|{
                                ch.send(QuickProfileCmd::Chat(chat_send.to_owned(), val));
                            }
                        }
                    )
                })
            }
        ))
        ,
        &cx.props.children
    }))
}
