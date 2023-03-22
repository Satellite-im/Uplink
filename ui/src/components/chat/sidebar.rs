use common::icons::outline::Shape as Icon;
use common::language::get_local_text;
use dioxus::prelude::*;
use dioxus_router::*;
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
use warp::{
    logging::tracing::log,
    raygun::{self},
};

use common::state::{self, Action, State};

use crate::{
    components::{chat::RouteInfo, media::remote_control::RemoteControls},
    utils::build_participants,
    UPLINK_ROUTES,
};

#[derive(PartialEq, Props)]
pub struct Props {
    route_info: RouteInfo,
}

#[allow(non_snake_case)]
pub fn Sidebar(cx: Scope<Props>) -> Element {
    log::trace!("rendering chats sidebar layout");
    let state = use_shared_state::<State>(cx)?;
    let router = use_router(cx);

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

    cx.render(rsx!(
        ReusableSidebar {
            hidden: state.read().ui.sidebar_hidden,
            with_search: cx.render(rsx!(
                div {
                    class: "search-input",
                    Input {
                        placeholder: get_local_text("uplink.search-placeholder"),
                        // TODO: Pending implementation
                        disabled: true,
                        aria_label: "chat-search-input".into(),
                        icon: Icon::MagnifyingGlass,
                        options: Options {
                            with_clear_btn: true,
                            ..Options::default()
                        }
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
                            appearance: Appearance::Secondary,
                            icon: Icon::ChatPlus,
                            tooltip: cx.render(rsx!(
                                Tooltip {
                                    arrow_position: ArrowPosition::Bottom,
                                    text: String::from("Create Group Chat")
                                }
                            )),
                            onpress: move |_| {
                                // using push_route here on purpose
                                router.push_route(UPLINK_ROUTES.create_group, None, None);
                            }
                        }
                    }
                )),
                sidebar_chats.iter().cloned().map(|chat| {
                    let users_typing = chat.typing_indicator.iter().any(|(k, _)| *k != state.read().did_key());
                    let participants = state.read().chat_participants(&chat);
                    let other_participants =  state.read().remove_self(&participants);
                    let user: state::Identity = other_participants.first().cloned().unwrap_or_default();
                    let platform = user.platform().into();

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

                    let participants_name = State::join_usernames(&other_participants);

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
                                        state.write().mutate(Action::ClearUnreads(clear_unreads.clone()));
                                    }
                                },
                                hr{ },
                                ContextItem {
                                    icon: Icon::PhoneArrowUpRight,
                                    text: get_local_text("uplink.call"),
                                    //TODO: Wire to state

                                },
                                hr{ }
                                ContextItem {
                                    icon: Icon::EyeSlash,
                                    text: get_local_text("uplink.hide-chat"),
                                    onpress: move |_| {
                                        state.write().mutate(Action::RemoveFromSidebar(chat.id));
                                    }
                                },
                            )),
                            User {
                                username: participants_name,
                                subtext: subtext_val,
                                timestamp: datetime,
                                active: is_active,
                                user_image: cx.render(rsx!(
                                    if participants.len() <= 2 {rsx! (
                                        UserImage {
                                            platform: platform,
                                            status:  user.identity_status().into(),
                                            image: user.graphics().profile_picture(),
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
