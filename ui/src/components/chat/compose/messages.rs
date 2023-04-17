use std::{ffi::OsStr, path::PathBuf, rc::Rc};

use dioxus::prelude::{EventHandler, *};

use futures::StreamExt;

use kit::components::{
    context_menu::{ContextItem, ContextMenu},
    indicator::Status,
    message::{Message, Order, ReactionAdapter},
    message_group::{MessageGroup, MessageGroupSkeletal},
    message_reply::MessageReply,
    user_image::UserImage,
};

use common::{
    icons::outline::Shape as Icon,
    icons::Icon as IconElement,
    state::{group_messages, GroupedMessage, MessageGroup},
    warp_runner::ui_adapter::{self},
};
use common::{
    state::{Action, Identity, State},
    warp_runner::{RayGunCmd, WarpCmd},
    WARP_CMD_CH,
};

use common::language::get_local_text;
use dioxus_desktop::use_eval;
use rfd::FileDialog;
#[cfg(target_os = "windows")]
use tokio::time::sleep;
use uuid::Uuid;
use warp::{
    crypto::DID,
    logging::tracing::log,
    multipass::identity::IdentityStatus,
    raygun::{self, ReactionState},
};

use crate::utils::format_timestamp::format_timestamp_timeago;

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

#[allow(clippy::large_enum_variant)]
enum MessagesCommand {
    React((DID, raygun::Message, String)),
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
pub fn get_messages(cx: Scope, data: Rc<super::ComposeData>) -> Element {
    log::trace!("get_messages");
    let state = use_shared_state::<State>(cx)?;

    let num_to_take = use_state(cx, || DEFAULT_NUM_TO_TAKE);
    let prev_chat_id = use_ref(cx, || data.active_chat.id);
    let newely_fetched_messages: &UseRef<Option<(Uuid, Vec<ui_adapter::Message>)>> =
        use_ref(cx, || None);

    let quick_profile_uuid = &*cx.use_hook(|| Uuid::new_v4().to_string());
    let identity_profile = use_state(cx, Identity::default);
    let update_script = use_state(cx, String::new);

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
                let script = include_str!("../scroll_to_bottom.js");
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
                    MessagesCommand::React((user, message, emoji)) => {
                        let (tx, rx) = futures::channel::oneshot::channel();
                        let reaction_state =
                            match message.reactions().iter().find(|x| x.emoji() == emoji) {
                                Some(reaction) if reaction.users().contains(&user) => {
                                    ReactionState::Remove
                                }
                                _ => ReactionState::Add,
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

    let msg_container_end = if data.active_chat.has_more_messages {
        rsx!(MessageGroupSkeletal {}, MessageGroupSkeletal { alt: true })
    } else {
        rsx!(
            div {
                // key: "encrypted-notification-0001",
                class: "msg-container-end",
                IconElement {
                    icon:  Icon::LockClosed,
                },
                p {
                    get_local_text("messages.msg-banner")
                }
            }
        )
    };

    cx.render(rsx!(
        div {
            id: "messages",
            div {
                rsx!(
                    msg_container_end,
                    render_message_groups{
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
                            let script = include_str!("../show_context.js")
                                .replace("UUID", quick_profile_uuid)
                                .replace("$PAGE_X", &e.page_coordinates().x.to_string())
                                .replace("$PAGE_Y", &e.page_coordinates().y.to_string());
                            update_script.set(script);
                        }
                    }
                )
            }
        },
        super::quick_profile::QuickProfileContext{
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
    let sender = state.read().get_identity(&group.sender).unwrap_or_default();
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
    let reacting_to: &UseState<Option<Uuid>> = use_state(cx, || None);

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
        let _msg_uuid = message.inner.id();

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
                msg_uuid: _msg_uuid,
                message_key: _message_key,
                reacting_to: reacting_to.clone(),
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
                    onpress: move |_| {
                        reacting_to.set(Some(_msg_uuid));
                    }
                },
                ContextItem {
                    icon: Icon::Pencil,
                    text: get_local_text("messages.edit"),
                    should_render: !cx.props.is_remote
                        && edit_msg.get().map(|id| id != _msg_uuid).unwrap_or(true),
                    onpress: move |_| {
                        edit_msg.set(Some(_msg_uuid));
                        log::debug!("editing msg {_msg_uuid}");
                    }
                },
                ContextItem {
                    icon: Icon::Pencil,
                    text: get_local_text("messages.cancel-edit"),
                    should_render: !cx.props.is_remote
                        && edit_msg.get().map(|id| id == _msg_uuid).unwrap_or(false),
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
    msg_uuid: Uuid,
    reacting_to: UseState<Option<Uuid>>,
    edit_msg: UseState<Option<Uuid>>,
}
fn render_message<'a>(cx: Scope<'a, MessageProps<'a>>) -> Element<'a> {
    //log::trace!("render message {}", &cx.props.message.message.key);
    let state = use_shared_state::<State>(cx)?;
    let user_did = state.read().did_key();

    // todo: why?
    #[cfg(not(target_os = "macos"))]
    let eval = use_eval(cx);

    let reactions = ["❤️", "😂", "😍", "💯", "👍", "😮", "😢", "😡", "🤔", "😎"];
    let ch = use_coroutine_handle::<MessagesCommand>(cx)?;
    let focus_script = r#"
            var message_reactions_container = document.getElementById('add-message-reaction');
            message_reactions_container.focus();
        "#;

    let MessageProps {
        message,
        is_remote,
        msg_uuid,
        message_key,
        reacting_to,
        edit_msg,
    } = cx.props;
    let grouped_message = message;
    let message = grouped_message.message;
    let is_editing = edit_msg
        .current()
        .map(|id| !cx.props.is_remote && (id == message.inner.id()))
        .unwrap_or(false);

    let reactions_list: Vec<ReactionAdapter> = message
        .inner
        .reactions()
        .iter()
        .map(|x| {
            let users = x.users();
            let user_names: Vec<String> = users
                .iter()
                .filter_map(|id| state.read().get_identity(id).map(|x| x.username()))
                .collect();
            ReactionAdapter {
                emoji: x.emoji(),
                reaction_count: users.len(),
                self_reacted: users.iter().any(|x| x == &user_did),
                alt: user_names.join(", "),
            }
        })
        .collect();

    let remote_class = if *is_remote { "" } else { "remote" };
    let reactions_class = format!("message-reactions-container {remote_class}");

    cx.render(rsx!(
        (*reacting_to.current() == Some(*msg_uuid)).then(|| {
            rsx!(
                div {
                    id: "add-message-reaction",
                    class: "{reactions_class} pointer",
                    tabindex: "0",
                    onmouseleave: |_| {
                        #[cfg(not(target_os = "macos"))] 
                        {
                            eval(focus_script.to_string());
                        }
                    },
                    onblur: move |_| {
                        reacting_to.set(None);
                    },
                    reactions.iter().cloned().map(|reaction| {
                        rsx!(
                            div {
                                onclick: move |_|  {
                                    reacting_to.set(None);
                                    ch.send(MessagesCommand::React((state.read().did_key(), message.inner.clone(), reaction.to_string())));
                                },
                                "{reaction}"
                            }
                        )
                    })
                },
                script { focus_script },
            )
        }),
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
                reactions: reactions_list,
                order: if grouped_message.is_first { Order::First } else if grouped_message.is_last { Order::Last } else { Order::Middle },
                attachments: message.inner.attachments(),
                on_click_reaction: move |emoji: String| {
                    ch.send(MessagesCommand::React((user_did.clone(), message.inner.clone(), emoji)));
                },
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
