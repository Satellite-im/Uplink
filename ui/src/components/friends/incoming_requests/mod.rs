use std::rc::Rc;

use crate::components::friends::friend::Friend;
use chrono::{Duration, Utc};
use common::icons::outline::Shape as Icon;
use common::language::get_local_text;
use common::{
    state::{Action, State},
    warp_runner::{MultiPassCmd, WarpCmd},
    STATIC_ARGS, WARP_CMD_CH,
};
use dioxus::prelude::*;
use futures::{channel::oneshot, StreamExt};
use kit::{
    components::{
        context_menu::{ContextItem, ContextMenu},
        user_image::UserImage,
    },
    elements::label::Label,
};
use rand::Rng;
use warp::crypto::DID;
use warp::{logging::tracing::log, multipass::identity::Relationship};

enum ChanCmd {
    AcceptRequest(DID),
    DenyRequest(DID),
}

#[allow(non_snake_case)]
pub fn PendingFriends(cx: Scope) -> Element {
    let state: UseSharedState<State> = use_shared_state::<State>(cx).unwrap();
    let friends_list = state.read().incoming_fr_identities();

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
                                did: identity,
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
                                did: identity,
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
                let friend = Rc::new(friend);
                let _username = friend.username();
                let _status_message = friend.status_message().unwrap_or_default();
                let mut rng = rand::thread_rng();
                let did = friend.did_key();
                let did_suffix: String = did.to_string().chars().rev().take(6).collect();
                let platform = friend.platform().into();
                let friend2 = friend.clone();
                let friend3 = friend.clone();
                let friend4 = friend.clone();
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
                                        state.write().mutate(Action::AcceptRequest(&friend));
                                    } else {
                                       ch.send(ChanCmd::AcceptRequest(friend.did_key()));
                                    }
                                }
                            },
                            ContextItem {
                                danger: true,
                                icon: Icon::XMark,
                                text: get_local_text("friends.deny"),
                                onpress: move |_| {
                                    if STATIC_ARGS.use_mock {
                                        state.write().mutate(Action::DenyRequest(&did));
                                    } else {
                                       ch.send(ChanCmd::DenyRequest(did.clone()));
                                    }
                                }
                            }
                        )),
                        Friend {
                            username: _username,
                            suffix: did_suffix,
                            status_message: _status_message,
                            relationship: {
                                let mut relationship = Relationship::default();
                                relationship.set_received_friend_request(true);
                                relationship
                            },
                            request_datetime: Utc::now() - Duration::days(rng.gen_range(0..30)),
                            user_image: cx.render(rsx! (
                                UserImage {
                                    platform: platform,
                                    status: friend2.identity_status().into(),
                                    image: friend2.profile_picture()
                                }
                            )),
                            onaccept: move |_| {
                                if STATIC_ARGS.use_mock {
                                    state.write().mutate(Action::AcceptRequest(&friend4));
                                } else {
                                     ch.send(ChanCmd::AcceptRequest(friend4.did_key()));
                                }

                            },
                            onremove: move |_| {
                                if STATIC_ARGS.use_mock {
                                    state.write().mutate(Action::AcceptRequest(&friend3));
                                } else {
                                    ch.send(ChanCmd::DenyRequest(friend3.did_key()));
                                }
                            }
                        }
                    }
                )
            })
        }
    ))
}
