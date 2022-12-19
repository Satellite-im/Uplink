use dioxus::prelude::*;
use fluent_templates::Loader;
use ui_kit::{
    components::{
        context_menu::ContextItem,
        context_menu::ContextMenu,
        indicator::{Platform, Status},
        user_image::UserImage,
    },
    elements::{
        button::Button,
        label::Label,
        tooltip::{ArrowPosition, Tooltip},
        Appearance,
    },
    icons::Icon,
};

use crate::{
    state::{Action, State},
    LOCALES, APP_LANG,
};

#[derive(Props)]
pub struct Props<'a> {
    // The username of the friend request sender
    username: String,
    // A suffix to the username, typically a unique identifier
    suffix: String,
    // The user image element to display
    user_image: Element<'a>,
    // An optional event handler for the "onchat" event
    #[props(optional)]
    onchat: Option<EventHandler<'a>>,
    // An optional event handler for the "onremove" event
    #[props(optional)]
    onremove: Option<EventHandler<'a>>,
    #[props(optional)]
    onaccept: Option<EventHandler<'a>>,
    // An optional event handler for the "onblock" event
    #[props(optional)]
    onblock: Option<EventHandler<'a>>,
}

#[allow(non_snake_case)]
pub fn Friend<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let chat_text = LOCALES
        .lookup(&*APP_LANG.read(), "uplink.chat")
        .unwrap_or_default();
    let block_text = LOCALES
        .lookup(&*APP_LANG.read(), "friends.block")
        .unwrap_or_default();
    let remove_text = LOCALES
        .lookup(&*APP_LANG.read(), "friends.remove")
        .unwrap_or_default();
    let deny_text = LOCALES
        .lookup(&*APP_LANG.read(), "friends.deny")
        .unwrap_or_default();
    let accept_text = LOCALES
        .lookup(&*APP_LANG.read(), "friends.accept")
        .unwrap_or_default();

    cx.render(rsx!(
        div {
            class: "friend",
            &cx.props.user_image,
            div {
                class: "request-info",
                p {
                    "{cx.props.username}",
                    span {
                        "#{cx.props.suffix}"
                    }
                },
                Label {
                    // TODO: this is stubbed for now, wire up to the actual request time
                    text: "Requested 4 days ago.".into()
                }
            },
            div {
                class: "request-controls",
                cx.props.onaccept.is_some().then(|| rsx!(
                    Button {
                        icon: Icon::Check,
                        text: accept_text,
                        onpress: move |_| match &cx.props.onaccept {
                            Some(f) => f.call(()),
                            None    => {},
                        }
                    }
                )),
                cx.props.onchat.is_some().then(|| rsx! (
                    Button {
                        icon: Icon::ChatBubbleBottomCenterText,
                        text: chat_text,
                        onpress: move |_| match &cx.props.onchat {
                            Some(f) => f.call(()),
                            None    => {},
                        }
                    }
                )),
                Button {
                    icon: Icon::XMark,
                    appearance: Appearance::Secondary,
                    onpress: move |_| match &cx.props.onremove {
                        Some(f) => f.call(()),
                        None    => {},
                    }
                    tooltip: cx.render(rsx!(
                        Tooltip {
                            arrow_position: ArrowPosition::Right,
                            text: if cx.props.onaccept.is_none() { remove_text } else { deny_text }
                        }
                    )),
                },
                cx.props.onchat.is_some().then(|| rsx!(
                    Button {
                        icon: Icon::NoSymbol,
                        appearance: Appearance::Secondary,
                        onpress: move |_| match &cx.props.onblock {
                            Some(f) => f.call(()),
                            None    => {},
                        }
                        tooltip: cx.render(rsx!(
                            Tooltip {
                                arrow_position: ArrowPosition::Right,
                                text: block_text
                            }
                        )),
                    }
                ))
            }
        }
    ))
}

#[allow(non_snake_case)]
pub fn Friends(cx: Scope) -> Element {
    let state: UseSharedState<State> = use_context::<State>(&cx).unwrap();
    let friends_list = state.read().friends.all.clone();
    let friends = State::get_friends_by_first_letter(friends_list);

    let friends_text = LOCALES.lookup(&*APP_LANG.read(), "friends").unwrap_or_default();

    cx.render(rsx! (
        div {
            class: "friends-list",
            Label {
                text: friends_text,
            },
            friends.into_iter().map(|(letter, sorted_friends)| {
                let group_letter = letter.to_string();
                rsx!(
                    div {
                        key: "friend-group-{group_letter}",
                        Label {
                            text: letter.into(),
                        },
                        sorted_friends.into_iter().map(|friend| {
                            let did = friend.did_key().clone();
                            let did_suffix: String = did.to_string().chars().rev().take(6).collect();
                            let chat_with_friend = state.read().get_chat_with_friend(&friend.clone());
                            let chat_with_friend_context = state.read().get_chat_with_friend(&friend.clone());
                            let chat_with_friend_context_clone = chat_with_friend_context.clone();
                            let remove_friend = friend.clone();
                            let remove_friend_2 = remove_friend.clone();
                            let block_friend = friend.clone();
                            let block_friend_clone = friend.clone();

                            let call_text = LOCALES
                                .lookup(&*APP_LANG.read(), "uplink.call")
                                .unwrap_or_default();
                            let chat_text = LOCALES
                                .lookup(&*APP_LANG.read(), "uplink.chat")
                                .unwrap_or_default();
                            let favorite_text = LOCALES
                                .lookup(&*APP_LANG.read(), "favorites")
                                .unwrap_or_default();
                            let remove_text = LOCALES
                                .lookup(&*APP_LANG.read(), "uplink.remove")
                                .unwrap_or_default();
                            let block_test = LOCALES
                                .lookup(&*APP_LANG.read(), "friends.block")
                                .unwrap_or_default();

                            rsx!(
                                ContextMenu {
                                    id: format!("{}-friend-listing", did),
                                    key: "{did}-friend-listing",
                                    items: cx.render(rsx!(
                                        ContextItem {
                                            icon: Icon::ChatBubbleBottomCenterText,
                                            text: chat_text,
                                            onpress: move |_| {
                                                let _ = &state.write().mutate(Action::ChatWith(chat_with_friend_context.clone()));
                                                use_router(&cx).replace_route("/", None, None);
                                            }
                                        },
                                        ContextItem {
                                            icon: Icon::PhoneArrowUpRight,
                                            text: call_text,
                                            // TODO: Wire this up to state
                                        },
                                        ContextItem {
                                            icon: Icon::Heart,
                                            text: favorite_text,
                                            onpress: move |_| {
                                                let _ = &state.write().mutate(Action::Favorite(chat_with_friend_context_clone.clone()));
                                            }
                                        },
                                        hr{}
                                        ContextItem {
                                            danger: true,
                                            icon: Icon::XMark,
                                            text: remove_text,
                                            onpress: move |_| {
                                                let _ = &state.write().mutate(Action::RemoveFriend(remove_friend.clone()));
                                            }
                                        },
                                        ContextItem {
                                            danger: true,
                                            icon: Icon::NoSymbol,
                                            text: block_test,
                                            onpress: move |_| {
                                                let _ = &state.write().mutate(Action::Block(block_friend.clone()));
                                            }
                                        },
                                    )),
                                    Friend {
                                        username: friend.username(),
                                        suffix: did_suffix,
                                        user_image: cx.render(rsx! (
                                            UserImage {
                                                platform: Platform::Desktop,
                                                status: Status::Online,
                                                image: friend.graphics().profile_picture()
                                            }
                                        )),
                                        onchat: move |_| {
                                            let _ = &state.write().mutate(Action::ChatWith(chat_with_friend.clone()));
                                            use_router(&cx).replace_route("/", None, None);
                                        },
                                        onremove: move |_| {
                                            let _ = &state.write().mutate(Action::RemoveFriend(remove_friend_2.clone()));
                                        },
                                        onblock: move |_| {
                                            let _ = &state.write().mutate(Action::Block(block_friend_clone.clone()));
                                        }
                                    }
                                }
                            )
                        })
                    }
                )
            })
        }
    ))
}

#[allow(non_snake_case)]
pub fn PendingFriends(cx: Scope) -> Element {
    let state: UseSharedState<State> = use_context::<State>(&cx).unwrap();
    let friends_list = state.read().friends.incoming_requests.clone();

    let requests_text = LOCALES
        .lookup(&*APP_LANG.read(), "friends.incoming_requests")
        .unwrap_or_default();

    cx.render(rsx! (
        div {
            class: "friends-list",
            Label {
                text: requests_text,
            },
            friends_list.into_iter().map(|friend| {
                let did = friend.did_key().clone();
                let did_suffix: String = did.to_string().chars().rev().take(6).collect();

                let deny_text = LOCALES
                    .lookup(&*APP_LANG.read(), "friends.deny")
                    .unwrap_or_default();

                let friend_clone = friend.clone();
                let friend_clone_clone = friend.clone();
                let friend_clone_clone_clone = friend.clone();

                rsx!(
                    ContextMenu {
                        id: format!("{}-friend-listing", did),
                        key: "{did}-friend-listing",
                        items: cx.render(rsx!(
                            ContextItem {
                                danger: true,
                                icon: Icon::XMark,
                                text: deny_text,
                                onpress: move |_| {
                                    let _ = state.write().mutate(Action::DenyRequest(friend_clone_clone_clone.clone()));
                                }
                            },
                        )),
                        Friend {
                            username: friend.username(),
                            suffix: did_suffix,
                            user_image: cx.render(rsx! (
                                UserImage {
                                    platform: Platform::Desktop,
                                    status: Status::Online,
                                    image: friend.graphics().profile_picture()
                                }
                            )),
                            onaccept: move |_| {
                                let _ = state.write().mutate(Action::AcceptRequest(friend_clone.clone()));
                            },
                            onremove: move |_| {
                                let _ = state.write().mutate(Action::DenyRequest(friend_clone_clone.clone()));
                            }
                        }
                    }
                )
            })
        }
    ))
}

#[allow(non_snake_case)]
pub fn OutgoingRequests(cx: Scope) -> Element {
    let state: UseSharedState<State> = use_context::<State>(&cx).unwrap();
    let friends_list = state.read().friends.outgoing_requests.clone();

    let requests_text = LOCALES
        .lookup(&*APP_LANG.read(), "friends.outgoing_requests")
        .unwrap_or_default();

    cx.render(rsx! (
        div {
            class: "friends-list",
            Label {
                text: requests_text,
            },
            friends_list.into_iter().map(|friend| {
                let did = friend.did_key().clone();
                let did_suffix: String = did.to_string().chars().rev().take(6).collect();

                let cancel_text = LOCALES
                    .lookup(&*APP_LANG.read(), "friends.cancel")
                    .unwrap_or_default();

                    let friend_clone = friend.clone();
                    let friend_clone_clone = friend.clone();

                rsx!(
                    ContextMenu {
                        id: format!("{}-friend-listing", did),
                        key: "{did}-friend-listing",
                        items: cx.render(rsx!(
                            ContextItem {
                                danger: true,
                                icon: Icon::XMark,
                                text: cancel_text,
                                onpress: move |_| {
                                    let _ = &state.write().mutate(Action::CancelRequest(friend_clone_clone.clone()));
                                }
                            },
                        )),
                        Friend {
                            username: friend.username(),
                            suffix: did_suffix,
                            user_image: cx.render(rsx! (
                                UserImage {
                                    platform: Platform::Desktop,
                                    status: Status::Online,
                                    image: friend.graphics().profile_picture()
                                }
                            )),
                            onremove: move |_| {
                                let _ = &state.write().mutate(Action::CancelRequest(friend_clone.clone()));
                            }
                        }
                    }
                )
            })
        }
    ))
}

#[allow(non_snake_case)]
pub fn BlockedUsers(cx: Scope) -> Element {
    let state: UseSharedState<State> = use_context::<State>(&cx).unwrap();
    let block_list = state.read().friends.blocked.clone();

    let blocked_text = LOCALES
        .lookup(&*APP_LANG.read(), "friends.blocked")
        .unwrap_or_default();

    cx.render(rsx! (
        div {
            class: "friends-list",
            Label {
                text: blocked_text,
            },
            block_list.into_iter().map(|blocked_user| {
                let did = blocked_user.did_key().clone();
                let did_suffix: String = did.to_string().chars().rev().take(6).collect();
                let unblock_user = blocked_user.clone();
                let unblock_user_clone = unblock_user.clone();
                let unblock_text = LOCALES
                    .lookup(&*APP_LANG.read(), "friends.unblock")
                    .unwrap_or_default();
                rsx!(
                    ContextMenu {
                        id: format!("{}-friend-listing", did),
                        key: "{did}-friend-listing",
                        items: cx.render(rsx!(
                            ContextItem {
                                danger: true,
                                icon: Icon::XMark,
                                text: unblock_text,
                                onpress: move |_| {
                                    state.write().mutate(Action::UnBlock(unblock_user.clone()));
                                }
                            },
                        )),
                        Friend {
                            username: blocked_user.username(),
                            suffix: did_suffix,
                            user_image: cx.render(rsx! (
                                UserImage {
                                    platform: Platform::Desktop,
                                    status: Status::Online,
                                    image: blocked_user.graphics().profile_picture()
                                }
                            )),
                            onremove: move |_| {
                                state.write().mutate(Action::UnBlock(unblock_user_clone.clone()));
                            }
                        }
                    }
                )
            })
        }
    ))
}
