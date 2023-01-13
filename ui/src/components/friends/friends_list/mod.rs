use dioxus::prelude::*;
use dioxus_router::use_router;
use futures::{channel::oneshot, StreamExt};
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
    state::{Action, Chat, Identity, State},
    utils::convert_status,
    warp_runner::{commands::RayGunCmd, WarpCmd},
    UPLINK_ROUTES, WARP_CMD_CH,
};

#[allow(non_snake_case)]
pub fn Friends(cx: Scope) -> Element {
    let state: UseSharedState<State> = use_shared_state::<State>(cx).unwrap();
    let friends_list = state.read().friends.all.clone();
    let friends = State::get_friends_by_first_letter(friends_list);
    let router = use_router(cx);

    let chat_with: &UseState<Option<Chat>> = use_state(cx, || None);

    if let Some(chat) = chat_with.get().clone() {
        chat_with.set(None);
        state.write().mutate(Action::ChatWith(chat));
        if state.read().ui.is_minimal_view() {
            state.write().mutate(Action::SidebarHidden(true));
        }
        router.replace_route(UPLINK_ROUTES.chat, None, None);
    }

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<(Identity, Option<Chat>)>| {
        to_owned![chat_with];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some((friend, chat)) = rx.next().await {
                // verify chat exists
                let chat = match chat {
                    Some(c) => c,
                    None => {
                        // if not, create the chat
                        let (tx, rx) = oneshot::channel::<Result<Chat, warp::error::Error>>();
                        warp_cmd_tx
                            .send(WarpCmd::RayGun(RayGunCmd::CreateConversation {
                                recipient: friend.did_key(),
                                rsp: tx,
                            }))
                            .expect("failed to send cmd");

                        let rsp = rx.await.expect("command cancelled");

                        match rsp {
                            Ok(c) => c,
                            Err(e) => {
                                println!("failed to create conversation: {}", e);
                                todo!()
                            }
                        }
                    }
                };
                chat_with.set(Some(chat));
            }
        }
    });

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
                            let chat = state.read().get_chat_with_friend(&friend);
                            let did_suffix: String = did.to_string().chars().rev().take(6).collect();
                            let mut relationship = Relationship::default();
                            relationship.set_friends(true);
                            let platform = match friend.platform() {
                                warp::multipass::identity::Platform::Desktop => Platform::Desktop,
                                warp::multipass::identity::Platform::Mobile => Platform::Mobile,
                                _ => Platform::Headless //TODO: Unknown
                            };
                            let friend2 = friend.clone();
                            let friend3 = friend.clone();
                            let friend4 = friend.clone();
                            let friend5 = friend.clone();
                            let friend6 = friend.clone();
                            let friend7 = friend.clone();
                            let chat2 = chat.clone();
                            let chat3 = chat.clone();
                            rsx!(
                                ContextMenu {
                                    id: format!("{}-friend-listing", did),
                                    key: "{did}-friend-listing",
                                    items: cx.render(rsx!(
                                        ContextItem {
                                            icon: Icon::ChatBubbleBottomCenterText,
                                            text: get_local_text("uplink.chat"),
                                            onpress: move |_| {
                                                ch.send((friend.clone(), chat2.clone()));
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
                                                // can't favorite a non-existent conversation
                                                // todo: don't even allow favoriting from the friends page unless there's a conversation
                                                if let Some(c) = &chat {
                                                    state.write().mutate(Action::Favorite(c.clone()));
                                                }
                                            }
                                        },
                                        hr{}
                                        ContextItem {
                                            danger: true,
                                            icon: Icon::UserMinus,
                                            text: get_local_text("uplink.remove"),
                                            onpress: move |_| {
                                                state.write().mutate(Action::RemoveFriend(friend2.clone()));
                                            }
                                        },
                                        ContextItem {
                                            danger: true,
                                            icon: Icon::NoSymbol,
                                            text: get_local_text("friends.block"),
                                            onpress: move |_| {
                                                state.write().mutate(Action::Block(friend3.clone()));
                                            }
                                        },
                                    )),
                                    Friend {
                                        username: friend4.username(),
                                        suffix: did_suffix,
                                        status_message: friend4.status_message().unwrap_or_default(),
                                        relationship: relationship,
                                        user_image: cx.render(rsx! (
                                            UserImage {
                                                platform: platform,
                                                status: convert_status(&friend4.identity_status()),
                                                image: friend4.graphics().profile_picture()
                                            }
                                        )),
                                        onchat: move |_| {
                                           ch.send((friend5.clone(), chat3.clone()));
                                        },
                                        onremove: move |_| {
                                            state.write().mutate(Action::RemoveFriend(friend6.clone()));
                                        },
                                        onblock: move |_| {
                                            state.write().mutate(Action::Block(friend7.clone()));
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
