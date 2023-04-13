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
use warp::{crypto::DID, logging::tracing::log, multipass::identity::Relationship};

#[allow(non_snake_case)]
pub fn OutgoingRequests(cx: Scope) -> Element {
    let state: UseSharedState<State> = use_shared_state::<State>(cx).unwrap();
    let friends_list = state.read().outgoing_fr_identities();

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<DID>| {
        //to_owned![];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(did) = rx.next().await {
                let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();
                if let Err(e) = warp_cmd_tx.send(WarpCmd::MultiPass(MultiPassCmd::CancelRequest {
                    did,
                    rsp: tx,
                })) {
                    log::error!("failed to send warp command: {}", e);
                    continue;
                }

                let rsp = rx.await.expect("command canceled");
                if let Err(e) = rsp {
                    log::error!("failed to cancel request: {}", e);
                }
            }
        }
    });

    cx.render(rsx! (
        div {
            class: "friends-list",
            aria_label: "Outgoing Requests List",
            Label {
                text: get_local_text("friends.outgoing_requests"),
            },
            friends_list.into_iter().map(|friend| {
                let did = friend.did_key();
                let did2 = did.clone();
                let did_suffix: String = did.to_string().chars().rev().take(6).collect();
                let mut rng = rand::thread_rng();
                let platform = friend.platform().into();
                rsx!(
                    ContextMenu {
                        id: format!("{did}-friend-listing"),
                        key: "{did}-friend-listing",
                        items: cx.render(rsx!(
                            ContextItem {
                                danger: true,
                                icon: Icon::XMark,
                                text: get_local_text("friends.cancel"),
                                onpress: move |_| {
                                    if STATIC_ARGS.use_mock {
                                        state.write().mutate(Action::CancelRequest(&did));
                                    } else {
                                        ch.send(did.clone());
                                    }
                                }
                            },
                        )),
                        Friend {
                            username: friend.username(),
                            suffix: did_suffix,
                            status_message: friend.status_message().unwrap_or_default(),
                            relationship: {
                                let mut relationship = Relationship::default();
                                relationship.set_sent_friend_request(true);
                                relationship
                            },
                            request_datetime: Utc::now() - Duration::days(rng.gen_range(0..30)),
                            user_image: cx.render(rsx! (
                                UserImage {
                                    platform: platform,
                                    status: friend.identity_status().into(),
                                    image: friend.profile_picture()
                                }
                            )),
                            onremove: move |_| {
                                if STATIC_ARGS.use_mock {
                                    state.write().mutate(Action::CancelRequest(&did2));
                                } else {
                                    ch.send(did2.clone());
                                }
                            }
                        }
                    }
                )
            })
        }
    ))
}
