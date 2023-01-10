use dioxus::prelude::*;
use dioxus_router::use_router;
use kit::{
    components::{
        context_menu::{ContextItem, ContextMenu},
        indicator::Platform,
        user_image::UserImage,
    },
    elements::label::Label,
    icons::Icon,
};

use shared::language::get_local_text;
use warp::multipass::identity::Relationship;

use crate::{
    components::friends::friend::{Friend, SkeletalFriend},
    state::{Action, State},
    UPLINK_ROUTES,
};

#[allow(non_snake_case)]
pub fn Friends(cx: Scope) -> Element {
    let state: UseSharedState<State> = use_shared_state::<State>(cx).unwrap();
    let friends_list = state.read().friends.all.clone();
    let friends = State::get_friends_by_first_letter(friends_list);

    cx.render(rsx! (
        div {
            class: "friends-list",
            Label {
                text: get_local_text("friends.friends"),
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
                            let did = friend.did_key();
                            let did_suffix: String = did.to_string().chars().rev().take(6).collect();
                            let chat_with_friend = state.read().get_chat_with_friend(&friend);
                            let chat_with_friend_context = state.read().get_chat_with_friend(&friend);
                            let chat_with_friend_context_clone = chat_with_friend_context.clone();
                            let remove_friend = friend.clone();
                            let remove_friend_2 = remove_friend.clone();
                            let block_friend = friend.clone();
                            let block_friend_clone = friend.clone();
                            let mut relationship = Relationship::default();
                            relationship.set_friends(true);
                            let platform = match friend.platform() {
                                warp::multipass::identity::Platform::Desktop => Platform::Desktop,
                                warp::multipass::identity::Platform::Mobile => Platform::Mobile,
                                _ => Platform::Headless //TODO: Unknown
                            };
                            rsx!(
                                ContextMenu {
                                    id: format!("{}-friend-listing", did),
                                    key: "{did}-friend-listing",
                                    items: cx.render(rsx!(
                                        ContextItem {
                                            icon: Icon::ChatBubbleBottomCenterText,
                                            text: get_local_text("uplink.chat"),
                                            onpress: move |_| {
                                                state.write().mutate(Action::ChatWith(chat_with_friend_context.clone()));
                                                use_router(cx).replace_route(UPLINK_ROUTES.chat, None, None);
                                            }
                                        },
                                        ContextItem {
                                            icon: Icon::PhoneArrowUpRight,
                                            text: get_local_text("uplink.call"),
                                            // TODO: Wire this up to state
                                        },
                                        ContextItem {
                                            icon: Icon::Heart,
                                            text: get_local_text("favorites.favorites"),
                                            onpress: move |_| {
                                                state.write().mutate(Action::Favorite(chat_with_friend_context_clone.clone()));
                                            }
                                        },
                                        hr{}
                                        ContextItem {
                                            danger: true,
                                            icon: Icon::UserMinus,
                                            text: get_local_text("uplink.remove"),
                                            onpress: move |_| {
                                                state.write().mutate(Action::RemoveFriend(remove_friend.clone()));
                                            }
                                        },
                                        ContextItem {
                                            danger: true,
                                            icon: Icon::NoSymbol,
                                            text: get_local_text("friends.block"),
                                            onpress: move |_| {
                                                state.write().mutate(Action::Block(block_friend.clone()));
                                            }
                                        },
                                    )),
                                    Friend {
                                        username: friend.username(),
                                        suffix: did_suffix,
                                        status_message: friend.status_message().unwrap_or_default(),
                                        relationship: relationship,
                                        user_image: cx.render(rsx! (
                                            UserImage {
                                                platform: platform,
                                                status: friend.identity_status().into(),
                                                image: friend.graphics().profile_picture()
                                            }
                                        )),
                                        onchat: move |_| {
                                            state.write().mutate(Action::ChatWith(chat_with_friend.clone()));
                                            use_router(cx).replace_route(UPLINK_ROUTES.chat, None, None);
                                        },
                                        onremove: move |_| {
                                            state.write().mutate(Action::RemoveFriend(remove_friend_2.clone()));
                                        },
                                        onblock: move |_| {
                                            state.write().mutate(Action::Block(block_friend_clone.clone()));
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
pub fn FriendsSkeletal(cx: Scope) -> Element {
    cx.render(rsx!(
        div {
            class: "friends-list",
            Label {
                text: get_local_text("friends.friends"),
            },
            SkeletalFriend {},
            SkeletalFriend {},
            SkeletalFriend {},
        }
    ))
}
