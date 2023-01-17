use crate::{
    components::friends::friend::Friend,
    state::{Identity, State},
    utils::convert_status,
    warp_runner::{commands::MultiPassCmd, WarpCmd},
    WARP_CMD_CH,
};
use chrono::{Duration, Utc};
use dioxus::prelude::*;
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
use rand::Rng;
use shared::language::get_local_text;
use warp::multipass::identity::Relationship;

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
                        warp_cmd_tx
                            .send(WarpCmd::MultiPass(MultiPassCmd::AcceptRequest {
                                did: identity.did_key(),
                                rsp: tx,
                            }))
                            .expect("failed to send cmd");

                        let rsp = rx.await.expect("command canceled");
                        if let Err(e) = rsp {
                            println!("failed to accept request: {}", e);
                            todo!()
                        }
                    }
                    ChanCmd::DenyRequest(identity) => {
                        let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();
                        warp_cmd_tx
                            .send(WarpCmd::MultiPass(MultiPassCmd::DenyRequest {
                                did: identity.did_key(),
                                rsp: tx,
                            }))
                            .expect("failed to send cmd");

                        let rsp = rx.await.expect("command canceled");
                        if let Err(e) = rsp {
                            println!("failed to deny request: {}", e);
                            todo!()
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
                let friend_clone = friend.clone();
                let friend_clone_clone = friend.clone();
                let friend_clone_clone_clone = friend.clone();
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
                                danger: true,
                                icon: Icon::XMark,
                                text: get_local_text("friends.deny"),
                                onpress: move |_| {
                                    ch.send(ChanCmd::DenyRequest(friend_clone_clone_clone.clone()));
                                }
                            },
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
                                ch.send(ChanCmd::AcceptRequest(friend_clone.clone()));
                            },
                            onremove: move |_| {
                               ch.send(ChanCmd::DenyRequest(friend_clone_clone.clone()));
                            }
                        }
                    }
                )
            })
        }
    ))
}
