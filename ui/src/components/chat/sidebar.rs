use common::language::get_local_text;
use common::state::{self, identity_search_result, Action, State};
use common::warp_runner::{RayGunCmd, WarpCmd};
use common::{icons::outline::Shape as Icon, WARP_CMD_CH};
use dioxus::prelude::*;
use dioxus_router::*;
use futures::channel::oneshot;
use futures::StreamExt;
use kit::{
    components::{
        context_menu::{ContextItem, ContextMenu},
        indicator::{Platform, Status},
        nav::Nav,
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
    logging::tracing::log,
    raygun::{self},
};

use crate::components::chat::create_group::CreateGroup;
use crate::{
    components::{chat::RouteInfo, media::remote_control::RemoteControls},
    utils::build_participants,
    UPLINK_ROUTES,
};

#[allow(clippy::large_enum_variant)]
enum MessagesCommand {
    CreateConversation { recipient: DID },
    DeleteConversation { conv_id: Uuid },
}

#[derive(PartialEq, Props)]
pub struct Props {
    route_info: RouteInfo,
}

#[derive(Props)]
pub struct SearchProps<'a> {
    // username, did
    identities: UseState<Vec<identity_search_result::Entry>>,
    onclick: EventHandler<'a, identity_search_result::Identifier>,
}
fn search_friends<'a>(cx: Scope<'a, SearchProps<'a>>) -> Element<'a> {
    if cx.props.identities.get().is_empty() {
        return None;
    }
    // todo: make this show up
    cx.render(rsx!(
        div {
            class: "searchbar-dropdown",
            cx.props.identities.get().iter().map(|entry| {
                rsx!(
                    a {
                        onclick: move |_| {
                            cx.props.onclick.call(entry.id.clone());
                        },
                        "{entry.display_name}"
                    }
                )
            })
        }
    ))
}

#[allow(non_snake_case)]
pub fn Sidebar(cx: Scope<Props>) -> Element {
    log::trace!("rendering chats sidebar layout");
    let state = use_shared_state::<State>(cx)?;
    let search_results = use_state(cx, Vec::<identity_search_result::Entry>::new);
    let chat_with: &UseState<Option<Uuid>> = use_state(cx, || None);
    let reset_searchbar = use_state(cx, || false);
    let router = use_router(cx);
    let show_delete_conversation = use_ref(cx, || true);

    if let Some(chat) = *chat_with.get() {
        chat_with.set(None);
        state.write().mutate(Action::ChatWith(&chat, true));
    }

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<MessagesCommand>| {
        to_owned![chat_with, show_delete_conversation];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(cmd) = rx.next().await {
                match cmd {
                    MessagesCommand::CreateConversation { recipient } => {
                        // if not, create the chat
                        let (tx, rx) = oneshot::channel();
                        if let Err(e) =
                            warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::CreateConversation {
                                recipient,
                                rsp: tx,
                            }))
                        {
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

                        if let Err(e) =
                            warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::DeleteConversation {
                                conv_id,
                                rsp: tx,
                            }))
                        {
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
    });

    let select_entry = move |id: identity_search_result::Identifier| match id {
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
    let (sidebar_chats, favorites, active_media_chat) = if state.read().chats().initialized {
        (
            state.read().chats_sidebar(),
            state.read().chats_favorites(),
            state.read().get_active_chat(),
        )
    } else {
        (vec![], vec![], None)
    };

    let show_create_group = use_state(cx, || false);

    let extensions = &state.read().ui.extensions;
    let ext_renders = extensions
        .values()
        .filter(|ext| ext.enabled())
        .filter(|ext| ext.details().location == extensions::Location::Sidebar)
        .map(|ext| rsx!(ext.render(cx.scope)))
        .collect::<Vec<_>>();

    cx.render(rsx!(
        ReusableSidebar {
            hidden: state.read().ui.sidebar_hidden,
            with_search: cx.render(rsx!(
                div {
                    class: "search-input",
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
                        onreturn: move |(v, _, _): (String, _, _)| {
                            if !v.is_empty() {
                                 if let Some(entry) = search_results.get().first() {
                                    select_entry(entry.id.clone());
                                }
                            }
                            search_results.set(Vec::new());
                        },
                        onchange: move |(v, _): (String, _)| {
                            if v.is_empty() {
                                search_results.set(Vec::new());
                            } else {
                                let mut friends = state.read().search_identities(&v);
                                let chats = state.read().search_group_chats(&v);
                                // todo: sort this somehow
                                friends.extend(chats);
                                search_results.set(friends);
                            }
                        },
                    }
                }
            ))
            with_nav: cx.render(rsx!(
                Nav {
                    routes: cx.props.route_info.routes.clone(),
                    active: cx.props.route_info.active.clone(),
                    onnavigate: move |r| {
                        if state.read().configuration.audiovideo.interface_sounds {
                            common::sounds::Play(common::sounds::Sounds::Interaction);
                        }
                        router.replace_route(r, None, None);
                    }
                },
            )),
            search_friends{ identities: search_results.clone(), onclick: move |entry| {
                select_entry(entry);
                search_results.set(Vec::new());
                reset_searchbar.set(true);
            } },
            // Load extensions
            for node in ext_renders {
                rsx!(node)
            },
            // Only display favorites if we have some.
            (!favorites.is_empty()).then(|| rsx!(
                div {
                    id: "favorites",
                    aria_label: "Favorites",
                    Label {
                        text: get_local_text("favorites.favorites"),
                    },
                    div {
                        class: "vertically-scrollable",
                        favorites.iter().cloned().map(|chat| {
                            let users_typing = chat.typing_indicator.iter().any(|(k, _)| *k != state.read().did_key());
                            let favorites_chat = chat.clone();
                            let remove_favorite = chat.clone();
                            let chat_id = chat.id;
                            let participants = state.read().chat_participants(&chat);
                            let other_participants: Vec<_> = state.read().remove_self(&participants);
                            rsx! (
                                ContextMenu {
                                    key: "{chat_id}-favorite",
                                    id: chat_id.to_string(),
                                    items: cx.render(rsx!(
                                        ContextItem {
                                            icon: Icon::ChatBubbleBottomCenterText,
                                            text: get_local_text("uplink.chat"),
                                            onpress: move |_| {
                                                if state.read().ui.is_minimal_view() {
                                                    state.write().mutate(Action::SidebarHidden(true));
                                                }
                                                state.write().mutate(Action::ChatWith(&favorites_chat.id, false));
                                                if cx.props.route_info.active.to != UPLINK_ROUTES.chat {
                                                    router.replace_route(UPLINK_ROUTES.chat, None, None);
                                                }
                                            }
                                        },
                                        ContextItem {
                                            icon: Icon::HeartSlash,
                                            text: get_local_text("favorites.remove"),
                                            onpress: move |_| {
                                                state.write().mutate(Action::ToggleFavorite(&remove_favorite.id));
                                            }
                                        }
                                    )),
                                    UserImageGroup {
                                        participants: build_participants(&other_participants),
                                        with_username: State::join_usernames(&other_participants),
                                        typing: users_typing,
                                        onpress: move |_| {
                                            if state.read().ui.is_minimal_view() {
                                                state.write().mutate(Action::SidebarHidden(true));
                                            }
                                            state.write().mutate(Action::ChatWith(&chat.id, false));
                                            if cx.props.route_info.active.to != UPLINK_ROUTES.chat {
                                                router.replace_route(UPLINK_ROUTES.chat, None, None);
                                            }
                                        }
                                    }
                                }
                            )
                        })
                    }
                }
            )),
            div {
                id: "chats",
                aria_label: "Chats",
                (!sidebar_chats.is_empty()).then(|| rsx!(
                    div {
                        class: "sidebar-chats-header",
                        Label {
                            text: get_local_text("uplink.chats"),
                        },
                        Button {
                            appearance: if *show_create_group.get() { Appearance::Primary } else { Appearance::Secondary },
                            icon: Icon::ChatPlus,
                            tooltip: cx.render(rsx!(
                                Tooltip {
                                    arrow_position: ArrowPosition::Right,
                                    text: String::from("Create Group Chat")
                                }
                            )),
                            onpress: move |_| {
                                show_create_group.set(!show_create_group.get());
                            }
                        }
                    }
                    show_create_group.then(|| rsx!(
                        CreateGroup {
                            oncreate: move |_| {
                                show_create_group.set(false);
                            }
                        }
                    )),
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

                    let badge = if chat.unreads > 0 {
                        chat.unreads.to_string()
                    } else { "".into() };
                    let key = chat.id;

                    let is_active = state.read().get_active_chat().map(|c| c.id) == Some(chat.id);
                    let chat_with = chat.clone();
                    let clear_unreads = chat.clone();

                    // todo: how to tell who is participating in a group chat if the chat has a conversation_name? 
                    let participants_name = match chat.conversation_name {
                        Some(name) => name,
                        None => State::join_usernames(&other_participants)
                    };

                    let subtext_val = match unwrapped_message.value().iter().map(|x| x.trim()).find(|x| !x.is_empty()) {
                        Some(v) => v.into(),
                        _ => match &unwrapped_message.attachments()[..] {
                            [] => get_local_text("sidebar.chat-new"),
                            [ file ] => file.name(),
                            _ => match participants.iter().find(|p| p.did_key()  == unwrapped_message.sender()).map(|x| x.username()) {
                                Some(name) => format!("{name} {}", get_local_text("sidebar.subtext")),
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
                            items: cx.render(rsx!(
                                ContextItem {
                                    icon: Icon::BellSlash,
                                    text: get_local_text("uplink.clear-unreads"),
                                    onpress: move |_| {
                                        state.write().mutate(Action::ClearUnreads(clear_unreads.id));
                                    }
                                },
                                hr{ }
                                ContextItem {
                                    icon: Icon::EyeSlash,
                                    text: get_local_text("uplink.hide-chat"),
                                    onpress: move |_| {
                                        state.write().mutate(Action::RemoveFromSidebar(chat.id));
                                    }
                                },
                                show_delete_conversation.read().then(||
                                    rsx!(
                                        hr{ }
                                        ContextItem {
                                            icon: Icon::Trash,
                                            danger: true,
                                            text: if is_group_conv && is_creator {get_local_text("uplink.delete-group-chat")} 
                                            else if is_group_conv && !is_creator  {get_local_text("uplink.leave-group")} 
                                            else {get_local_text("uplink.delete-conversation")},
                                            onpress: move |_| {
                                                ch.send(MessagesCommand::DeleteConversation { conv_id: chat.id });
                                            }
                                        },
                                    )
                                )
                            )),
                            User {
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
                                            typing: users_typing,
                                        }
                                    )}
                                )),
                                with_badge: badge,
                                onpress: move |_| {
                                    state.write().mutate(Action::ChatWith(&chat_with.id, false));
                                    if cx.props.route_info.active.to != UPLINK_ROUTES.chat {
                                        router.replace_route(UPLINK_ROUTES.chat, None, None);
                                    }
                                    if state.read().ui.is_minimal_view() {
                                        state.write().mutate(Action::SidebarHidden(true));
                                    }
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
            active_media_chat.is_some().then(|| rsx!(
                RemoteControls {
                    in_call_text: get_local_text("remote-controls.in-call"),
                    mute_text: get_local_text("remote-controls.mute"),
                    unmute_text: get_local_text("remote-controls.unmute"),
                    listen_text: get_local_text("remote-controls.listen"),
                    silence_text: get_local_text("remote-controls.silence"),
                    end_text: get_local_text("remote-controls.end"),
                }
            )),
        }
    ))
}
