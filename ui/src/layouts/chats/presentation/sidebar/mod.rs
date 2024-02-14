mod create_group;
mod search;

use common::language::{get_local_text, get_local_text_with_args};
use common::state::ui::Layout;
use common::state::{self, identity_search_result, Action, Chat, Identity, State};
use common::warp_runner::{RayGunCmd, WarpCmd};
use common::{icons::outline::Shape as Icon, WARP_CMD_CH};
use dioxus::html::input_data::keyboard_types::Code;
use dioxus::prelude::*;
use dioxus_router::prelude::use_navigator;
use futures::channel::oneshot;
use futures::StreamExt;
use kit::components::message::format_text;
use kit::layout::modal::Modal;
use kit::{
    components::{
        context_menu::{ContextItem, ContextMenu},
        indicator::{Platform, Status},
        user::User,
        user_image::UserImage,
        user_image_group::UserImageGroup,
    },
    elements::{
        button::Button,
        input::{Input, Options},
        label::Label,
        tooltip::{ArrowPosition, Tooltip},
        Appearance,
    },
    layout::sidebar::Sidebar as ReusableSidebar,
};
use uuid::Uuid;
use warp::raygun::ConversationType;
use warp::{
    crypto::DID,
    raygun::{self},
};

use tracing::log;

use crate::components::file_transfer::FileTransferModal;
use crate::components::media::calling::CallControl;

use crate::layouts::chats::presentation::sidebar::create_group::CreateGroup;
use crate::utils::build_participants;
use crate::UplinkRoute;

#[allow(clippy::large_enum_variant)]
enum MessagesCommand {
    CreateConversation { recipient: DID },
    DeleteConversation { conv_id: Uuid },
}

#[derive(PartialEq, Props)]
pub struct SidebarProps {
    pub active_route: UplinkRoute,
}

#[allow(non_snake_case)]
pub fn Sidebar(cx: Scope<SidebarProps>) -> Element {
    log::trace!("rendering chats sidebar layout");
    let state = use_shared_state::<State>(cx)?;
    let search_results = use_state(cx, Vec::<identity_search_result::Entry>::new);
    let search_results_friends_identities = use_state(cx, Vec::<Identity>::new);
    let search_results_chats = use_state(cx, Vec::<Chat>::new);
    let chat_with: &UseState<Option<Uuid>> = use_state(cx, || None);
    let reset_searchbar = use_state(cx, || false);
    let router = use_navigator(cx);
    let show_delete_conversation = use_ref(cx, || true);
    let on_search_dropdown_hover = use_ref(cx, || false);
    let search_friends_is_focused = use_ref(cx, || false);
    let storage = state.read().ui.current_layout == Layout::Storage;

    if let Some(chat) = *chat_with.get() {
        chat_with.set(None);
        state.write().mutate(Action::ChatWith(&chat, true));
        router.replace(UplinkRoute::ChatLayout {});
    }

    let ch = use_coroutine(cx, |rx: UnboundedReceiver<MessagesCommand>| {
        conversation_coroutine(rx, chat_with.clone(), show_delete_conversation.clone())
    });

    let select_identifier = move |id: identity_search_result::Identifier| match id {
        identity_search_result::Identifier::Did(did) => {
            if let Some(c) = state.read().get_chat_with_friend(did.clone()) {
                chat_with.set(Some(c.id));
            } else {
                ch.send(MessagesCommand::CreateConversation { recipient: did });
            }
        }
        identity_search_result::Identifier::Uuid(id) => {
            if let Some(c) = state.read().get_chat_by_id(id) {
                chat_with.set(Some(c.id));
            } else {
                log::warn!("failed to select chat {id}");
            }
        }
    };

    // todo: display a loading page if chats is not initialized
    let sidebar_chats = if state.read().initialized {
        state.read().chats_sidebar()
    } else {
        vec![]
    };

    let show_create_group = use_state(cx, || false);

    let extensions = &state.read().ui.extensions;
    let ext_renders = extensions
        .values()
        .filter(|(_, ext)| ext.details().location == extensions::Location::Sidebar)
        .map(|(_, ext)| rsx!(ext.render(cx.scope)))
        .collect::<Vec<_>>();
    let search_typed_chars = use_ref(cx, String::new);

    cx.render(rsx!(
        ReusableSidebar {
            hidden: state.read().ui.sidebar_hidden,
            with_search: cx.render(rsx!(
                div {
                    class: "search-input disable-select",
                    Input {
                        placeholder: get_local_text("uplink.search-placeholder"),
                        // TODO: Pending implementation
                        disabled: false,
                        aria_label: "chat-search-input".into(),
                        icon: Icon::MagnifyingGlass,
                        reset: reset_searchbar.clone(),
                        options: Options {
                            with_clear_btn: true,
                            react_to_esc_key: true,
                            clear_on_submit: true,
                            ..Options::default()
                        },
                        onreturn: move |(v, _, key): (String, _, Code)| {
                            if key == Code::Escape {
                                *search_friends_is_focused.write() = false;
                            }
                            if !v.is_empty() && on_search_dropdown_hover.with(|i| !(*i))  {
                                 if let Some(entry) = search_results.get().first() {
                                    if !*search_friends_is_focused.read() {
                                        select_identifier(entry.id.clone());
                                    }
                                }
                                search_results.set(Vec::new());
                            }
                        },
                        onchange: move |(v, _): (String, _)| {
                            if v.is_empty() {
                                search_results.set(Vec::new());
                                *search_friends_is_focused.write_silent() = false;
                            } else {
                                let (mut friends_entries, friends_identities) = state.read().search_identities(&v);
                                let (chats_entries, chats) = state.read().search_group_chats(&v);
                                friends_entries.extend(chats_entries);
                                // todo: sort this somehow
                                search_results.set(friends_entries);
                                search_results_friends_identities.set(friends_identities);
                                search_results_chats.set(chats);
                                *search_typed_chars.write_silent() = v;
                                *search_friends_is_focused.write_silent() = true;
                                on_search_dropdown_hover.with_mut(|i| *i = false);
                            }
                        },
                    }
                }
            )),
            with_nav: cx.render(rsx!(
                crate::AppNav {
                    active: match state.read().ui.current_layout {
                        state::ui::Layout::Welcome => UplinkRoute::ChatLayout{},
                        state::ui::Layout::Compose => UplinkRoute::ChatLayout{},
                        state::ui::Layout::Friends => UplinkRoute::FriendsLayout {},
                        state::ui::Layout::Settings => UplinkRoute::SettingsLayout {},
                        state::ui::Layout::Storage => UplinkRoute::FilesLayout {},
                    },
                    onnavigate: move |_| {
                        if state.read().configuration.audiovideo.interface_sounds {
                            common::sounds::Play(common::sounds::Sounds::Interaction);
                        }
                        if state.read().ui.is_minimal_view() {
                            state.write().mutate(Action::SidebarHidden(true));
                        }
                    }
                }
            )),
            with_call_controls: cx.render(rsx!(
                CallControl {
                    in_chat: false
                }
            )),
            if *search_friends_is_focused.read() {
                render! { search::search_friends {
                    search_typed_chars: search_typed_chars.clone(),
                    search_friends_is_focused: search_friends_is_focused.clone(),
                    identities: search_results.clone(),
                    friends_identities: search_results_friends_identities.clone(),
                    chats: search_results_chats.clone(),
                    search_dropdown_hover: on_search_dropdown_hover.clone(),
                    onclick: move |identifier: identity_search_result::Identifier| {
                        select_identifier(identifier);
                        search_results.set(Vec::new());
                        reset_searchbar.set(true);
                        on_search_dropdown_hover.with_mut(|i| *i = false);
                    }
                }}
            },
            // Load extensions
            for node in ext_renders {
                rsx!(node)
            },
            div {
                id: "chats",
                aria_label: "Chats",
                (!sidebar_chats.is_empty()).then(|| rsx!(
                    div {
                        class: "sidebar-chats-header",
                        Label {
                            text: get_local_text("uplink.chats"),
                            aria_label: "chats-label".into(),
                        },
                        Button {
                            appearance: if *show_create_group.get() { Appearance::Primary } else { Appearance::Secondary },
                            aria_label: "create-group-chat".into(),
                            icon: Icon::ChatPlus,
                            tooltip: cx.render(rsx!(
                                Tooltip {
                                    arrow_position: ArrowPosition::Right,
                                    text: get_local_text("messages.create-group-chat")
                                }
                            )),
                            onpress: move |_| {
                                show_create_group.set(!show_create_group.get());
                            }
                        }
                    }
                    show_create_group.then(|| {
                        let clss = format!(
                            "create-group-modal {}",
                            if state.read().ui.is_minimal_view() {
                                "minimal"
                            } else {
                                ""
                            }
                        );
                        rsx!(
                        Modal {
                            class: "{clss}",
                            open: *show_create_group.clone(),
                            with_title: get_local_text("messages.create-group-chat"),
                            transparent: true,
                            onclose: move |_| {
                                show_create_group.set(false);
                            },
                            CreateGroup {
                                oncreate: move |_| {
                                    show_create_group.set(false);
                                }
                            }
                        }
                    )}),
                )),
                sidebar_chats.iter().cloned().map(|chat| {
                    let users_typing = chat.typing_indicator.iter().any(|(k, _)| *k != state.read().did_key());
                    let participants = state.read().chat_participants(&chat);
                    let other_participants =  state.read().remove_self(&participants);
                    let user: state::Identity = other_participants.first().cloned().unwrap_or_default();
                    let platform = user.platform().into();
                    let is_group_conv =  chat.conversation_type == ConversationType::Group;
                    let is_creator = chat.creator.as_ref().map(|x| x == &state.read().did_key()).unwrap_or_default();

                    let last_message = chat.messages.iter().last();
                    let unwrapped_message = match last_message {
                        Some(m) => m.inner.clone(),
                        // conversation with no messages yet
                        None => raygun::Message::default(),
                    };

                    let datetime = unwrapped_message.date();

                    let has_unreads = chat.unreads() > 0;
                    let badge = if chat.unreads() > 0 {
                        chat.unreads().to_string()
                    } else { "".into() };
                    let key = chat.id;

                    let is_active = state.read().get_active_chat().map(|c| c.id) == Some(chat.id);
                    let chat_with = chat.clone();
                    let clear_unreads = chat.clone();
                    let markdown = false;
                    let should_transform_ascii_emojis = state.read().ui.should_transform_ascii_emojis();

                    // todo: how to tell who is participating in a group chat if the chat has a conversation_name?
                    let participants_name = match chat.conversation_name {
                        Some(name) => name,
                        None => State::join_usernames(&other_participants)
                    };

                    let subtext_val = match unwrapped_message.lines().iter().map(|x| x.trim()).find(|x| !x.is_empty()) {
                        Some(v) => {
                            format_text(v, markdown, should_transform_ascii_emojis, Some((&state.read(), &chat.id, true)))
                        }
                        _ => match &unwrapped_message.attachments()[..] {
                            [] => get_local_text("sidebar.chat-new"),
                            [ file ] => file.name(),
                            _ => match participants.iter().find(|p| p.did_key()  == unwrapped_message.sender()).map(|x| x.username()) {
                                Some(name) => get_local_text_with_args("sidebar.subtext", vec![("user", name)]),
                                None => {
                                    log::error!("error calculating subtext for sidebar chat");
                                    // Still return default message
                                    get_local_text("sidebar.chat-new")
                                }
                            }
                        }
                    };

                    // TODO:
                    // let _block_user_text = LOCALES
                    //     .lookup(&*APP_LANG.read(), "friends.block")
                    //     .unwrap_or_default();

                    rsx!(
                        ContextMenu {
                            key: "{key}-chat",
                            id: format!("{key}-chat"),
                            devmode: state.read().configuration.developer.developer_mode,
                            items: cx.render(rsx!(
                                ContextItem {
                                    icon: Icon::BellSlash,
                                    aria_label: "chats-clear-unreads".into(),
                                    text: get_local_text("uplink.clear-unreads"),
                                    should_render: has_unreads,
                                    onpress: move |_| {
                                        state.write().mutate(Action::ClearUnreads(clear_unreads.id));
                                    }
                                },
                                ContextItem {
                                    icon: Icon::EyeSlash,
                                    aria_label: "chats-hide-chat".into(),
                                    text: get_local_text("uplink.hide-chat"),
                                    onpress: move |_| {
                                        state.write().mutate(Action::RemoveFromSidebar(chat.id));
                                    }
                                },
                                show_delete_conversation.read().then(||
                                    rsx!(
                                        ContextItem {
                                            icon: Icon::Trash,
                                            danger: true,
                                            text: if is_group_conv && is_creator {get_local_text("uplink.delete-group-chat")}
                                            else if is_group_conv && !is_creator  {get_local_text("uplink.leave-group")}
                                            else {get_local_text("uplink.delete-conversation")},
                                            aria_label: if is_group_conv && is_creator {"chats-delete-group".into()}
                                            else if is_group_conv && !is_creator {"chats-leave-group".into()}
                                            else {"chats-delete-conversation".into()},
                                            onpress: move |_| {
                                                ch.send(MessagesCommand::DeleteConversation { conv_id: chat.id });
                                            }
                                        },
                                    )
                                )
                            )),
                            User {
                                aria_label: participants_name.clone(),
                                username: participants_name,
                                subtext: subtext_val,
                                timestamp: datetime,
                                active: is_active,
                                user_image: cx.render(rsx!(
                                    if chat.conversation_type == ConversationType::Direct {rsx! (
                                        UserImage {
                                            platform: platform,
                                            status:  user.identity_status().into(),
                                            image: user.profile_picture(),
                                            typing: users_typing,
                                        }
                                    )} else {rsx! (
                                        UserImageGroup {
                                            participants: build_participants(&participants),
                                            aria_label: "user-image-group".into(),
                                            typing: users_typing,
                                        }
                                    )}
                                )),
                                with_badge: badge,
                                onpress: move |_| {
                                    state.write().mutate(Action::ChatWith(&chat_with.id, false));

                                    if state.read().ui.is_minimal_view() {
                                        state.write().mutate(Action::SidebarHidden(true));
                                    }
                                    router.replace(UplinkRoute::ChatLayout {  });
                                }
                            }
                        }
                    )}
                ),
                sidebar_chats.is_empty().then(|| rsx!(
                    div {
                        class: "skeletal-steady",
                        User {
                            loading: true,
                            username: "Loading".into(),
                            aria_label: "Loading".into(),
                            subtext: "loading".into(),
                            user_image: cx.render(rsx!(
                                UserImage {
                                    platform: Platform::Mobile,
                                    status: Status::Online,
                                    loading: true
                                }
                            ))
                        },
                        User {
                            loading: true,
                            username: "Loading".into(),
                            aria_label: "Loading".into(),
                            subtext: "loading".into(),
                            user_image: cx.render(rsx!(
                                UserImage {
                                    platform: Platform::Mobile,
                                    status: Status::Online,
                                    loading: true
                                }
                            ))
                        },
                        User {
                            loading: true,
                            username: "Loading".into(),
                            aria_label: "Loading".into(),
                            subtext: "loading".into(),
                            user_image: cx.render(rsx!(
                                UserImage {
                                    platform: Platform::Mobile,
                                    status: Status::Online,
                                    loading: true
                                }
                            ))
                        },
                    }
                ))
            },
            storage.then(||
                rsx!(FileTransferModal {
                    state: state,
                })
            )
        }
    ))
}

async fn conversation_coroutine(
    mut rx: UnboundedReceiver<MessagesCommand>,
    chat_with: UseState<Option<Uuid>>,
    show_delete_conversation: UseRef<bool>,
) {
    let warp_cmd_tx = WARP_CMD_CH.tx.clone();
    while let Some(cmd) = rx.next().await {
        match cmd {
            MessagesCommand::CreateConversation { recipient } => {
                // if not, create the chat
                let (tx, rx) = oneshot::channel();
                if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::CreateConversation {
                    recipient,
                    rsp: tx,
                })) {
                    log::error!("failed to send warp command: {}", e);
                    continue;
                }

                let rsp = rx.await.expect("command canceled");

                match rsp {
                    Ok(c) => chat_with.set(Some(c)),
                    Err(e) => {
                        log::error!("failed to create conversation: {}", e);
                        continue;
                    }
                };
            }
            MessagesCommand::DeleteConversation { conv_id } => {
                *show_delete_conversation.write_silent() = false;
                let (tx, rx) = futures::channel::oneshot::channel();

                if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::DeleteConversation {
                    conv_id,
                    rsp: tx,
                })) {
                    log::error!("failed to send warp command: {}", e);
                    continue;
                }

                let res = rx.await.expect("command canceled");
                if res.is_err() {
                    log::error!("failed to delete conversation");
                }
                *show_delete_conversation.write_silent() = true;
            }
        };
    }
}
