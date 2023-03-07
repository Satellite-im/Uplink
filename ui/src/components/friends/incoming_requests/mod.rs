use crate::{components::friends::friend::Friend, utils::convert_status};
use chrono::{Duration, Utc};
use common::icons::outline::Shape as Icon;
use common::language::get_local_text;
use common::{
    state::{Action, Identity, State},
    warp_runner::{MultiPassCmd, WarpCmd},
    STATIC_ARGS, WARP_CMD_CH,
};
use dioxus::prelude::*;
use futures::{channel::oneshot, StreamExt};
use kit::{
    components::{
        context_menu::{ContextItem, ContextMenu},
        indicator::Platform,
        user_image::UserImage,
    },
    elements::label::Label,
};
use rand::Rng;
use warp::{logging::tracing::log, multipass::identity::Relationship};

enum ChanCmd {
    AcceptRequest(Identity),
    DenyRequest(Identity),
}

#[allow(non_snake_case)]
pub fn PendingFriends(cx: Scope) -> Element {
    let state: UseSharedState<State> = use_shared_state::<State>(cx).unwrap();
    let friends_list = state.read().friends.incoming_requests.clone();

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<ChanCmd>| {
        //to_owned![];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(cmd) = rx.next().await {
                match cmd {
                    ChanCmd::AcceptRequest(identity) => {
                        let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();
                        if let Err(e) =
                            warp_cmd_tx.send(WarpCmd::MultiPass(MultiPassCmd::AcceptRequest {
                                did: identity.did_key(),
                                rsp: tx,
                            }))
                        {
                            log::error!("failed to send warp command: {}", e);
                            continue;
                        }

                        let rsp = rx.await.expect("command canceled");
                        if let Err(e) = rsp {
                            log::error!("failed to accept request: {}", e);
                        }
                    }
                    ChanCmd::DenyRequest(identity) => {
                        let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();
                        if let Err(e) =
                            warp_cmd_tx.send(WarpCmd::MultiPass(MultiPassCmd::DenyRequest {
                                did: identity.did_key(),
                                rsp: tx,
                            }))
                        {
                            log::error!("failed to send warp command: {}", e);
                            continue;
                        }

                        let rsp = rx.await.expect("command canceled");
                        if let Err(e) = rsp {
                            log::error!("failed to deny request: {}", e);
                        }
                    }
                }
            }
        }
    });

    cx.render(rsx! (
        div {
            class: "friends-list",
            aria_label: "Incoming Requests List",
            Label {
                text: get_local_text("friends.incoming_requests"),
            },
            friends_list.into_iter().map(|friend| {
                let mut rng = rand::thread_rng();
                let did = friend.did_key();
                let did_suffix: String = did.to_string().chars().rev().take(6).collect();
                let friend_clone_accept = friend.clone();
                let friend_clone_remove = friend.clone();
                let friend_clone_ctx_accept = friend.clone();
                let friend_clone_ctx_deny = friend.clone();
                let platform = match friend.platform() {
                    warp::multipass::identity::Platform::Desktop => Platform::Desktop,
                    warp::multipass::identity::Platform::Mobile => Platform::Mobile,
                    _ => Platform::Headless //TODO: Unknown
                };
                rsx!(
                    ContextMenu {
                        id: format!("{did}-friend-listing"),
                        key: "{did}-friend-listing",
                        items: cx.render(rsx!(
                            ContextItem {
                                danger: true,
                                icon: Icon::Check,
                                text: get_local_text("friends.accept"),
                                onpress: move |_| {
                                    if STATIC_ARGS.use_mock {
                                        state.write().mutate(Action::AcceptRequest(friend_clone_ctx_accept.clone()));
                                    } else {
                                       ch.send(ChanCmd::AcceptRequest(friend_clone_ctx_accept.clone()));
                                    }
                                }
                            },
                            ContextItem {
                                danger: true,
                                icon: Icon::XMark,
                                text: get_local_text("friends.deny"),
                                onpress: move |_| {
                                    if STATIC_ARGS.use_mock {
                                        state.write().mutate(Action::DenyRequest(friend_clone_ctx_deny.clone()));
                                    } else {
                                       ch.send(ChanCmd::DenyRequest(friend_clone_ctx_deny.clone()));
                                    }
                                }
                            }
                        )),
                        Friend {
                            username: friend.username(),
                            suffix: did_suffix,
                            status_message: friend.status_message().unwrap_or_default(),
                            relationship: {
                                let mut relationship = Relationship::default();
                                relationship.set_received_friend_request(true);
                                relationship
                            },
                            request_datetime: Utc::now() - Duration::days(rng.gen_range(0..30)),
                            user_image: cx.render(rsx! (
                                UserImage {
                                    platform: platform,
                                    status: convert_status(&friend.identity_status()),
                                    image: friend.graphics().profile_picture()
                                }
                            )),
                            onaccept: move |_| {
                                if STATIC_ARGS.use_mock {
                                    state.write().mutate(Action::AcceptRequest(friend_clone_accept.clone()));
                                } else {
                                     ch.send(ChanCmd::AcceptRequest(friend_clone_accept.clone()));
                                }

                            },
                            onremove: move |_| {
                                if STATIC_ARGS.use_mock {
                                    state.write().mutate(Action::AcceptRequest(friend_clone_remove.clone()));
                                } else {
                                    ch.send(ChanCmd::DenyRequest(friend_clone_remove.clone()));
                                }
                            }
                        }
                    }
                )
            })
        }
    ))
}
