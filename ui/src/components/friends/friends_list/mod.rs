use std::collections::HashMap;

use dioxus::prelude::*;
use dioxus_router::use_router;
use futures::{channel::oneshot, StreamExt};
use kit::{
    components::{
        context_menu::{ContextItem, ContextMenu},
        user_image::UserImage,
    },
    elements::label::Label,
};

use common::icons::outline::Shape as Icon;
use common::language::get_local_text;
use common::{
    state::{Action, Chat, State},
    warp_runner::{MultiPassCmd, RayGunCmd, WarpCmd},
    STATIC_ARGS, WARP_CMD_CH,
};
use uuid::Uuid;
use warp::{crypto::DID, logging::tracing::log, multipass::identity::Relationship};

use crate::{
    components::friends::friend::{Friend, SkeletalFriend},
    UPLINK_ROUTES,
};

#[allow(clippy::large_enum_variant)]
enum ChanCmd {
    CreateConversation { recipient: DID, chat: Option<Chat> },
    RemoveFriend(DID),
    BlockFriend(DID),
    // will remove direct conversations involving the friend
    RemoveDirectConvs(DID),
}

#[allow(non_snake_case)]
pub fn Friends(cx: Scope) -> Element {
    let state: UseSharedState<State> = use_shared_state::<State>(cx).unwrap();
    let friends_list = HashMap::from_iter(
        state
            .read()
            .friend_identities()
            .iter()
            .map(|id| (id.did_key(), id.clone())),
    );
    let friends = State::get_friends_by_first_letter(friends_list);
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

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<ChanCmd>| {
        to_owned![chat_with];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(cmd) = rx.next().await {
                match cmd {
                    ChanCmd::CreateConversation { chat, recipient } => {
                        // verify chat exists
                        let chat = match chat {
                            Some(c) => c.id,
                            None => {
                                // if not, create the chat
                                let (tx, rx) = oneshot::channel();
                                if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(
                                    RayGunCmd::CreateConversation { recipient, rsp: tx },
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
                    ChanCmd::RemoveFriend(did) => {
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
                    ChanCmd::BlockFriend(did) => {
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
                    ChanCmd::RemoveDirectConvs(recipient) => {
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
                }
            }
        }
    });

    cx.render(rsx! (
        div {
            class: "friends-list",
            aria_label: "Friends List",
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
                            let chat = state.read().get_chat_with_friend(friend.did_key());
                            let chat2 = chat.clone();
                            let chat3 = chat.clone();
                            let favorite = chat.clone().map(|c| state.read().is_favorite(&c));
                            let did_suffix: String = friend.short_id();
                            let remove_friend = friend.clone();
                            let remove_friend_2 = friend.clone();
                            let chat_with_friend = friend.clone();
                            let block_friend = friend.clone();
                            let block_friend_2 = friend.clone();
                            let context_friend = friend.clone();
                            let mut relationship = Relationship::default();
                            relationship.set_friends(true);
                            let platform = friend.platform().into();
                            rsx!(
                                ContextMenu {
                                    id: format!("{did}-friend-listing"),
                                    key: "{did}-friend-listing",
                                    items: cx.render(rsx!(
                                        ContextItem {
                                            icon: Icon::ChatBubbleBottomCenterText,
                                            text: get_local_text("uplink.chat"),
                                            onpress: move |_| {
                                                ch.send(ChanCmd::CreateConversation{recipient: context_friend.did_key(), chat: chat2.clone()});
                                            }
                                        },
                                        if let Some(f) = favorite {
                                            rsx!(ContextItem {
                                                icon: if f {Icon::HeartSlash} else {Icon::Heart},
                                                text: get_local_text(if f {"favorites.remove"} else {"favorites.favorites"}),
                                                onpress: move |_| {
                                                    // can't favorite a non-existent conversation
                                                    // todo: don't even allow favoriting from the friends page unless there's a conversation
                                                    if let Some(c) = &chat {
                                                        state.write().mutate(Action::ToggleFavorite(&c.id));
                                                    }
                                                }
                                            })
                                        },
                                        hr{}
                                        ContextItem {
                                            danger: true,
                                            icon: Icon::UserMinus,
                                            text: get_local_text("uplink.remove"),
                                            onpress: move |_| {
                                                if STATIC_ARGS.use_mock {
                                                    state.write().mutate(Action::RemoveFriend(&remove_friend.did_key()));
                                                } else {
                                                    ch.send(ChanCmd::RemoveFriend(remove_friend.did_key()));
                                                    ch.send(ChanCmd::RemoveDirectConvs(remove_friend.did_key()));
                                                }
                                            }
                                        },
                                        ContextItem {
                                            danger: true,
                                            icon: Icon::NoSymbol,
                                            text: get_local_text("friends.block"),
                                            onpress: move |_| {
                                                if STATIC_ARGS.use_mock {
                                                    state.write().mutate(Action::Block(&block_friend.did_key()));
                                                } else {
                                                    ch.send(ChanCmd::BlockFriend(block_friend.did_key()));
                                                    ch.send(ChanCmd::RemoveDirectConvs(block_friend.did_key()));
                                                }
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
                                                image: friend.profile_picture()
                                            }
                                        )),
                                        onchat: move |_| {
                                            // this works for mock data because the conversations already exist
                                           ch.send(ChanCmd::CreateConversation{recipient: chat_with_friend.did_key(), chat: chat3.clone()});
                                        },
                                        onremove: move |_| {
                                            if STATIC_ARGS.use_mock {
                                                state.write().mutate(Action::RemoveFriend(&remove_friend_2.did_key()));
                                            } else {
                                                ch.send(ChanCmd::RemoveFriend(remove_friend_2.did_key()));
                                                ch.send(ChanCmd::RemoveDirectConvs(remove_friend_2.did_key()));
                                            }
                                        },
                                        onblock: move |_| {
                                            if STATIC_ARGS.use_mock {
                                                state.write().mutate(Action::Block(&block_friend_2.did_key()));
                                            } else {
                                                ch.send(ChanCmd::BlockFriend(block_friend_2.did_key()));
                                                ch.send(ChanCmd::RemoveDirectConvs(block_friend_2.did_key()));
                                            }
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

// todo: remove this
#[allow(unused)]
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
