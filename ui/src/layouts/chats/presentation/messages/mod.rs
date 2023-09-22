use std::{
    collections::{HashMap, HashSet},
    ffi::OsStr,
    path::PathBuf,
    rc::Rc,
};

use dioxus::prelude::{EventHandler, *};

mod coroutines;
mod effects;

use kit::components::{
    context_menu::{ContextItem, ContextMenu},
    indicator::Status,
    message::{Message, Order, ReactionAdapter},
    message_group::MessageGroup,
    message_reply::MessageReply,
    user_image::UserImage,
};

use common::state::{Action, Identity, State};
use common::{
    icons::outline::Shape as Icon,
    icons::Icon as IconElement,
    language::get_local_text_with_args,
    state::{
        create_message_groups, pending_group_messages, pending_message::PendingMessage,
        scope_ids::ScopeIds, ui::EmojiDestination, GroupedMessage, MessageGroup, ToastNotification,
    },
    warp_runner::ui_adapter::{self},
};

use common::language::get_local_text;
use rfd::FileDialog;

use uuid::Uuid;
use warp::{
    crypto::DID,
    logging::tracing::log,
    multipass::identity::IdentityStatus,
    raygun::{self},
};

use crate::{
    components::emoji_group::EmojiGroup,
    layouts::chats::{
        data::ChatData,
        scripts::{READ_SCROLL, SHOW_CONTEXT},
    },
    utils::format_timestamp::format_timestamp_timeago,
};

#[allow(clippy::large_enum_variant)]
pub enum MessagesCommand {
    React((DID, raygun::Message, String)),
    DeleteMessage {
        conv_id: Uuid,
        msg_id: Uuid,
    },
    DownloadAttachment {
        conv_id: Uuid,
        msg_id: Uuid,
        file: warp::constellation::file::File,
        file_path_to_download: PathBuf,
    },
    EditMessage {
        conv_id: Uuid,
        msg_id: Uuid,
        msg: Vec<String>,
    },
    FetchMore {
        conv_id: Uuid,
        to_fetch: usize,
        current_len: usize,
    },
    Pin(raygun::Message),
}

pub type DownloadTracker = HashMap<Uuid, HashSet<warp::constellation::file::File>>;

pub struct NewelyFetchedMessages {
    conversation_id: Uuid,
    messages: Vec<ui_adapter::Message>,
    has_more: bool,
}

/// Lazy loading scheme:
/// load DEFAULT_NUM_TO_TAKE messages to start.
/// tell group_messages to flag the first X messages.
/// if onmouseout triggers over any of those messages, load Y more.
const DEFAULT_NUM_TO_TAKE: usize = 20;
#[component(no_case_check)]
pub fn get_messages(cx: Scope, data: Rc<ChatData>) -> Element {
    log::trace!("get_messages");
    use_shared_state_provider(cx, || -> DownloadTracker { HashMap::new() });
    let state = use_shared_state::<State>(cx)?;
    let pending_downloads = use_shared_state::<DownloadTracker>(cx)?;

    let prev_chat_id = use_ref(cx, || data.active_chat.id);
    let newly_fetched_messages: &UseRef<Option<NewelyFetchedMessages>> = use_ref(cx, || None);

    let quick_profile_uuid = &*cx.use_hook(|| Uuid::new_v4().to_string());
    let identity_profile = use_state(cx, Identity::default);
    let update_script = use_state(cx, String::new);

    // this needs to be a hook so it can change inside of the use_future.
    // it could be passed in as a dependency but then the wait would reset every time a message comes in.
    let max_to_take = use_ref(cx, || data.active_chat.messages.len());

    let active_chat = use_ref(cx, || None);
    let eval = use_eval(cx);

    if *max_to_take.read() != data.active_chat.messages.len() {
        *max_to_take.write_silent() = data.active_chat.messages.len();
    }

    let currently_active = Some(data.active_chat.id);

    if *active_chat.read() != currently_active {
        *active_chat.write_silent() = currently_active;
    }

    effects::update_chat_messages(cx, state, newly_fetched_messages);

    // don't scroll to the bottom again if new messages come in while the user is scrolling up. only scroll
    // to the bottom when the user selects the active chat
    // also must reset num_to_take when the active_chat changes
    effects::check_message_scroll(
        cx,
        &data.active_chat.scroll_to,
        state,
        eval,
        &currently_active,
    );

    effects::scroll_to_bottom(
        cx,
        data.active_chat.scroll_value,
        eval,
        data.active_chat.unreads(),
        data.active_chat.id,
        prev_chat_id,
    );

    let _ch =
        coroutines::handle_warp_commands(cx, state, newly_fetched_messages, pending_downloads);

    let msg_container_end = if data.active_chat.has_more_messages {
        rsx!(div {
            class: "fetching",
            p {
                IconElement {
                    icon: Icon::Loader,
                    class: "spin",
                },
                get_local_text("messages.fetching")
            }
        })
    } else {
        rsx!(
            div {
                // key: "encrypted-notification-0001",
                class: "msg-container-end",
                aria_label: "messages-secured-alert",
                p {
                    IconElement {
                        icon:  Icon::LockClosed,
                    },
                    get_local_text("messages.msg-banner")
                }
            }
        )
    };

    cx.render(rsx!(
        div {
            id: "messages",
            onscroll: move |_| {
                let update = cx.schedule_update_any();
                to_owned![eval, update, state, active_chat];
                async move {
                    if let Ok(val) = eval(READ_SCROLL) {
                        if let Ok(result) = val.join().await {
                            if let Some(uuid) = active_chat.read().as_ref() {
                                state.write_silent().update_chat_scroll(*uuid, result.as_i64().unwrap_or_default());
                                if let Some(id) = state.read().scope_ids.chatbar{
                                    update(ScopeIds::scope_id_from_usize(id));
                                };
                            }
                        }
                    }
                }
            },
            span {
                rsx!(
                    msg_container_end,
                    loop_over_message_groups {
                        groups: create_message_groups(data.my_id.did_key(), DEFAULT_NUM_TO_TAKE, data.active_chat.has_more_messages, &data.active_chat.messages),
                        active_chat_id: data.active_chat.id,
                        num_messages_in_conversation: data.active_chat.messages.len(),
                        on_context_menu_action: move |(e, id): (Event<MouseData>, Identity)| {
                            let own = state.read().get_own_identity().did_key().eq(&id.did_key());
                            if !identity_profile.get().eq(&id) {
                                let id = if own {
                                    let mut id = id;
                                    id.set_identity_status(IdentityStatus::Online);
                                    id
                                } else {
                                    id
                                };
                                identity_profile.set(id);
                            }
                            //Dont think there is any way of manually moving elements via dioxus
                            let script = SHOW_CONTEXT
                                .replace("UUID", quick_profile_uuid)
                                .replace("$PAGE_X", &e.page_coordinates().x.to_string())
                                .replace("$PAGE_Y", &e.page_coordinates().y.to_string())
                                .replace("$SELF", &own.to_string());
                            update_script.set(script);
                        }
                    },
                    render_pending_messages_listener {
                        data: data,
                        on_context_menu_action: move |(e, mut id): (Event<MouseData>, Identity)| {
                            let own = state.read().get_own_identity().did_key().eq(&id.did_key());
                            if !identity_profile.get().eq(&id) {
                                if own {
                                    id.set_identity_status(IdentityStatus::Online);
                                }
                                identity_profile.set(id);
                            }
                            //Dont think there is any way of manually moving elements via dioxus
                            let script = SHOW_CONTEXT
                                .replace("UUID", quick_profile_uuid)
                                .replace("$PAGE_X", &e.page_coordinates().x.to_string())
                                .replace("$PAGE_Y", &e.page_coordinates().y.to_string())
                                .replace("$SELF", &own.to_string());
                            update_script.set(script);
                        }
                    }
                )
            }
        },
        super::quick_profile::QuickProfileContext{
            id: quick_profile_uuid,
            update_script: update_script,
            did_key: identity_profile.did_key()
        }
    ))
}

#[derive(Props)]
pub struct AllMessageGroupsProps<'a> {
    groups: Vec<MessageGroup<'a>>,
    active_chat_id: Uuid,
    num_messages_in_conversation: usize,
    on_context_menu_action: EventHandler<'a, (Event<MouseData>, Identity)>,
}

// attempting to move the contents of this function into the above rsx! macro causes an error: cannot return vale referencing
// temporary location
pub fn loop_over_message_groups<'a>(cx: Scope<'a, AllMessageGroupsProps<'a>>) -> Element<'a> {
    log::trace!("render message groups");
    cx.render(rsx!(cx.props.groups.iter().map(|_group| {
        rsx!(render_message_group {
            group: _group,
            active_chat_id: cx.props.active_chat_id,
            num_messages_in_conversation: cx.props.num_messages_in_conversation,
            on_context_menu_action: move |e| cx.props.on_context_menu_action.call(e)
        },)
    })))
}

#[derive(Props)]
pub struct PendingMessagesListenerProps<'a> {
    data: &'a Rc<ChatData>,
    on_context_menu_action: EventHandler<'a, (Event<MouseData>, Identity)>,
}

//The component that listens for upload events
pub fn render_pending_messages_listener<'a>(
    cx: Scope<'a, PendingMessagesListenerProps>,
) -> Element<'a> {
    let state = use_shared_state::<State>(cx)?;
    state.write_silent().scope_ids.pending_message_component = Some(cx.scope_id().0);
    let chat = match state.read().get_active_chat() {
        Some(c) => c,
        None => return cx.render(rsx!(())),
    };
    cx.render(rsx!(pending_wrapper {
        msg: chat.pending_outgoing_messages,
        data: cx.props.data.clone(),
        on_context_menu_action: move |e| cx.props.on_context_menu_action.call(e)
    }))
}

#[derive(Props)]
struct PendingWrapperProps<'a> {
    msg: Vec<PendingMessage>,
    data: Rc<ChatData>,
    on_context_menu_action: EventHandler<'a, (Event<MouseData>, Identity)>,
}

//We need to do it this way due to reference ownership
fn pending_wrapper<'a>(cx: Scope<'a, PendingWrapperProps>) -> Element<'a> {
    cx.render(rsx!(render_pending_messages {
        pending_outgoing_message: pending_group_messages(
            &cx.props.msg,
            cx.props.data.my_id.did_key(),
        ),
        active: cx.props.data.active_chat.id,
        on_context_menu_action: move |e| cx.props.on_context_menu_action.call(e)
    }))
}

#[derive(Props)]
struct PendingMessagesProps<'a> {
    #[props(!optional)]
    pending_outgoing_message: Option<MessageGroup<'a>>,
    active: Uuid,
    on_context_menu_action: EventHandler<'a, (Event<MouseData>, Identity)>,
}

fn render_pending_messages<'a>(cx: Scope<'a, PendingMessagesProps>) -> Element<'a> {
    cx.render(rsx!(cx.props.pending_outgoing_message.as_ref().map(
        |group| {
            rsx!(render_message_group {
                group: group,
                active_chat_id: cx.props.active,
                num_messages_in_conversation: group.messages.len(),
                on_context_menu_action: move |e| cx.props.on_context_menu_action.call(e),
                pending: true
            },)
        }
    )))
}

#[derive(Props)]
struct MessageGroupProps<'a> {
    group: &'a MessageGroup<'a>,
    active_chat_id: Uuid,
    num_messages_in_conversation: usize,
    on_context_menu_action: EventHandler<'a, (Event<MouseData>, Identity)>,
    pending: Option<bool>,
}

fn render_message_group<'a>(cx: Scope<'a, MessageGroupProps<'a>>) -> Element<'a> {
    let state = use_shared_state::<State>(cx)?;

    let MessageGroupProps {
        group,
        active_chat_id: _,
        num_messages_in_conversation: _,
        on_context_menu_action: _,
        pending: _,
    } = cx.props;

    let messages = &group.messages;
    let last_message = messages.last().unwrap().message;
    let sender = state.read().get_identity(&group.sender).unwrap_or_default();
    let blocked = group.remote && state.read().is_blocked(&sender.did_key());
    let show_blocked = use_state(cx, || false);

    let blocked_element = if blocked {
        if !show_blocked.get() {
            return cx.render(rsx!(
                div {
                    class: "blocked-container",
                    p {
                        get_local_text_with_args("messages.blocked", vec![("amount", messages.len().into())])
                    },
                    p {
                        style: "white-space: pre",
                        " - "
                    },
                    div {
                        class: "pressable",
                        onclick: move |_| {
                            show_blocked.set(true);
                        },
                        get_local_text("messages.view")
                    }
                }
            ));
        }
        cx.render(rsx!(
            div {
                class: "blocked-container",
                p {
                    get_local_text_with_args("messages.blocked", vec![("amount", messages.len().into())])
                },
                p {
                    style: "white-space: pre",
                    " - "
                },
                div {
                    class: "pressable",
                    onclick: move |_| {
                        show_blocked.set(false);
                    },
                    get_local_text("messages.hide")
                }
            }
        ))
    } else {
        Option::None
    };
    let sender_clone = sender.clone();
    let sender_name = if sender.username().is_empty() {
        get_local_text("uplink.unknown")
    } else {
        sender.username()
    };
    let active_language = &state.read().settings.language_id();

    let mut sender_status = sender.identity_status().into();
    if !group.remote && sender_status == Status::Offline {
        sender_status = Status::Online;
    }

    cx.render(rsx!(
        blocked_element,
        MessageGroup {
            user_image: render!(UserImage {
                image: sender.profile_picture(),
                platform: sender.platform().into(),
                status: sender_status,
                on_press: move |e| {
                    cx.props.on_context_menu_action.call((e, sender.to_owned()));
                },
                oncontextmenu: move |e| {
                    cx.props
                        .on_context_menu_action
                        .call((e, sender_clone.to_owned()));
                }
            }),
            timestamp: format_timestamp_timeago(last_message.inner.date(), active_language),
            sender: sender_name.clone(),
            remote: group.remote,
            children: cx.render(rsx!(wrap_messages_in_context_menu {
                messages: &group.messages,
                active_chat_id: cx.props.active_chat_id,
                is_remote: group.remote,
                num_messages_in_conversation: cx.props.num_messages_in_conversation,
                pending: cx.props.pending.unwrap_or_default()
            }))
        },
    ))
}

#[derive(Props)]
struct MessagesProps<'a> {
    messages: &'a Vec<GroupedMessage<'a>>,
    active_chat_id: Uuid,
    num_messages_in_conversation: usize,
    is_remote: bool,
    pending: bool,
}
fn wrap_messages_in_context_menu<'a>(cx: Scope<'a, MessagesProps<'a>>) -> Element<'a> {
    let state = use_shared_state::<State>(cx)?;
    let edit_msg: &UseState<Option<Uuid>> = use_state(cx, || None);
    // see comment in ContextMenu about this variable.
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
        let message_key = format!("{}-{:?}", &message.key, is_editing);
        let message_id = format!("{}-{:?}", &message.inner.id(), is_editing);
        let context_key = format!("message-{}", &message_id);
        let msg_uuid = message.inner.id();
        let conversation_id = message.inner.conversation_id();

        if cx.props.pending {
            return rsx!(render_message {
                message: grouped_message,
                is_remote: cx.props.is_remote,
                message_key: message_key,
                edit_msg: edit_msg.clone(),
                pending: cx.props.pending
            });
        }

        // todo: add onblur event
        rsx!(ContextMenu {
            key: "{context_key}",
            id: context_key,
            devmode: state.read().configuration.developer.developer_mode,
            on_mouseenter: move |_| {
                if should_fetch_more {
                    ch.send(MessagesCommand::FetchMore {
                        conv_id: cx.props.active_chat_id,
                        to_fetch: DEFAULT_NUM_TO_TAKE * 2,
                        current_len: cx.props.num_messages_in_conversation,
                    });
                }
            },
            children: cx.render(rsx!(render_message {
                message: grouped_message,
                is_remote: cx.props.is_remote,
                message_key: message_key,
                edit_msg: edit_msg.clone(),
                pending: cx.props.pending
            })),
            items: cx.render(rsx!(
                ContextItem {
                    text: "Emoji Group".into(),
                    EmojiGroup {
                        onselect: move |emoji: String| {
                            log::trace!("reacting with emoji: {}", emoji);
                            ch.send(MessagesCommand::React((state.read().did_key(), message.inner.clone(), emoji)));
                        },
                        apply_to: EmojiDestination::Message(conversation_id, msg_uuid),
                    }
                },
                ContextItem {
                    icon: Icon::Pin,
                    aria_label: "messages-pin".into(),
                    text: if message.inner.pinned() {get_local_text("messages.unpin")} else {get_local_text("messages.pin")},
                    onpress: move |_| {
                        log::trace!("pinning message: {}", message.inner.id());
                        if state.read().reached_max_pinned(&message.inner.conversation_id()) {
                            state.write().mutate(Action::AddToastNotification(ToastNotification::init(
                                "".into(),
                                get_local_text("messages.pinned-max"),
                                None,
                                3,
                            )));
                        } else {
                            ch.send(MessagesCommand::Pin(message.inner.clone()));
                        }
                    }
                },
                ContextItem {
                    icon: Icon::ArrowLongLeft,
                    aria_label: "messages-reply".into(),
                    text: get_local_text("messages.reply"),
                    onpress: move |_| {
                        state
                            .write()
                            .mutate(Action::StartReplying(&cx.props.active_chat_id, message));
                    }
                },
                ContextItem {
                    icon: Icon::FaceSmile,
                    aria_label: "messages-react".into(),
                    text: get_local_text("messages.react"),
                    onpress: move |_| {
                        state.write().ui.ignore_focus = true;
                        state.write().mutate(Action::SetEmojiDestination(
                            // Tells the default emojipicker where to place the next emoji
                            Some(
                                common::state::ui::EmojiDestination::Message(conversation_id, msg_uuid)
                            )
                        ));
                        reacting_to.set(Some(msg_uuid));
                        state.write().mutate(Action::SetEmojiPickerVisible(true));
                    }
                },
                ContextItem {
                    icon: Icon::Pencil,
                    aria_label: "messages-edit".into(),
                    text: get_local_text("messages.edit"),
                    should_render: !cx.props.is_remote
                        && edit_msg.get().map(|id| id != msg_uuid).unwrap_or(true),
                    onpress: move |_| {
                        edit_msg.set(Some(msg_uuid));
                        state.write().ui.ignore_focus = true;
                    }
                },
                ContextItem {
                    icon: Icon::Pencil,
                    aria_label: "messages-cancel-edit".into(),
                    text: get_local_text("messages.cancel-edit"),
                    should_render: !cx.props.is_remote
                        && edit_msg.get().map(|id| id == msg_uuid).unwrap_or(false),
                    onpress: move |_| {
                        edit_msg.set(None);
                        state.write().ui.ignore_focus = false;
                    }
                },
                ContextItem {
                    icon: Icon::Trash,
                    danger: true,
                    aria_label: "messages-delete".into(),
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
    pending: bool,
}
fn render_message<'a>(cx: Scope<'a, MessageProps<'a>>) -> Element<'a> {
    //log::trace!("render message {}", &cx.props.message.message.key);
    let state = use_shared_state::<State>(cx)?;
    let pending_downloads = use_shared_state::<DownloadTracker>(cx)?;
    let user_did = state.read().did_key();

    // todo: why?
    #[cfg(not(target_os = "macos"))]
    let _eval = use_eval(cx);

    let ch = use_coroutine_handle::<MessagesCommand>(cx)?;

    let MessageProps {
        message,
        is_remote: _,
        message_key,
        edit_msg,
        pending: _,
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

    let user_did_2 = user_did.clone();
    let pending_uploads = grouped_message
        .attachment_progress
        .map(|m| m.values().cloned().collect())
        .unwrap_or(vec![]);

    cx.render(rsx!(
        // (*reacting_to.current() == Some(*msg_uuid)).then(|| {
        //     rsx!(
        //         div {
        //             id: "add-message-reaction",
        //             aria_label: "add-message-reaction",
        //             class: "{reactions_class} pointer",
        //             tabindex: "0",
        //             onmouseleave: |_| {
        //                 #[cfg(not(target_os = "macos"))]
        //                 {
        //                     eval(focus_script.to_string());
        //                 }
        //             },
        //             onblur: move |_| {
        //                 state.write().ui.ignore_focus = false;
        //                 reacting_to.set(None);
        //             },
        //             reactions.iter().cloned().map(|reaction| {
        //                 rsx!(
        //                     div {
        //                         aria_label: "{reaction}",
        //                         onclick: move |_|  {
        //                             reacting_to.set(None);
        //                             state.write().ui.ignore_focus = false;
        //                             ch.send(MessagesCommand::React((state.read().did_key(), message.inner.clone(), reaction.to_string())));
        //                         },
        //                         "{reaction}"
        //                     }
        //                 )
        //             })
        //         },
        //         script { focus_script },
        //     )
        // }),
        div {
            class: "msg-wrapper",
            message.in_reply_to.as_ref().map(|(other_msg, other_msg_attachments, sender_did)| rsx!(
            MessageReply {
                    key: "reply-{message_key}",
                    with_text: other_msg.to_string(),
                    with_attachments: other_msg_attachments.clone(),
                    remote: cx.props.is_remote,
                    remote_message: cx.props.is_remote,
                    sender_did: sender_did.clone(),
                    replier_did: user_did_2.clone(),
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
                attachments: message
                .inner
                .attachments(),
                attachments_pending_download: pending_downloads.read().get(&message.inner.conversation_id()).cloned(),
                on_click_reaction: move |emoji: String| {
                    ch.send(MessagesCommand::React((user_did.clone(), message.inner.clone(), emoji)));
                },
                pending: cx.props.pending,
                pinned: message.inner.pinned(),
                attachments_pending_uploads: pending_uploads,
                parse_markdown: true,
                on_download: move |file: warp::constellation::file::File| {
                    let file_name = file.name();
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
                        let conv_id = message.inner.conversation_id();
                        if !pending_downloads.read().contains_key(&conv_id) {
                            pending_downloads.write().insert(conv_id, HashSet::new());
                        }
                        pending_downloads.write().get_mut(&conv_id).map(|conv| conv.insert(file.clone()));

                        ch.send(MessagesCommand::DownloadAttachment {
                            conv_id,
                            msg_id: message.inner.id(),
                            file,
                            file_path_to_download
                        })
                    }
                },
                on_edit: move |update: String| {
                    edit_msg.set(None);
                    state.write().ui.ignore_focus = false;
                    let msg = update.split('\n').map(|x| x.to_string()).collect::<Vec<String>>();
                    if  message.inner.value() == msg || !msg.iter().any(|x| !x.trim().is_empty()) {
                        return;
                    }
                    ch.send(MessagesCommand::EditMessage { conv_id: message.inner.conversation_id(), msg_id: message.inner.id(), msg})
                }
            },
            script {
                r#"
                (() => {{
                    Prism.highlightAll();
                }})();
                "#
            } // Highlights Pre blocks
        }
    ))
}
