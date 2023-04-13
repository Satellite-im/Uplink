use crate::components::friends::friend::Friend;
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
use warp::{crypto::DID, error::Error, logging::tracing::log, multipass::identity::Relationship};

#[allow(non_snake_case)]
pub fn BlockedUsers(cx: Scope) -> Element {
    let state = use_shared_state::<State>(cx).unwrap();
    let block_list = state.read().blocked_fr_identities();

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<DID>| {
        //to_owned![];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(did) = rx.next().await {
                let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();
                if let Err(e) =
                    warp_cmd_tx.send(WarpCmd::MultiPass(MultiPassCmd::Unblock { did, rsp: tx }))
                {
                    log::error!("failed to send warp command: {}", e);
                    continue;
                }

                let rsp = rx.await.expect("command canceled");
                if let Err(e) = rsp {
                    match e {
                        Error::PublicKeyIsntBlocked => {}
                        _ => {
                            log::error!("failed to unblock user: {}", e);
                        }
                    }
                }
            }
        }
    });

    cx.render(rsx! (
        div {
            class: "friends-list",
            aria_label: "Blocked List",
            Label {
                text: get_local_text("friends.blocked"),
            },
            block_list.into_iter().map(|blocked_user| {
                let did = blocked_user.did_key();
                let did_suffix: String = did.to_string().chars().rev().take(6).collect();
                let unblock_user = blocked_user.clone();
                let unblock_user_clone = unblock_user.clone();
                let platform = blocked_user.platform().into();
                let mut relationship = Relationship::default();
                relationship.set_blocked(true);
                rsx!(
                    ContextMenu {
                        id: format!("{did}-friend-listing"),
                        key: "{did}-friend-listing",
                        items: cx.render(rsx!(
                            ContextItem {
                                danger: true,
                                icon: Icon::XMark,
                                text: get_local_text("friends.unblock"),
                                onpress: move |_| {
                                    if STATIC_ARGS.use_mock {
                                        state.write().mutate(Action::Unblock(&unblock_user.did_key()));
                                    } else {
                                        ch.send(unblock_user.clone().did_key());
                                    }
                                }
                            },
                        )),
                        Friend {
                            username: blocked_user.username(),
                            suffix: did_suffix,
                            status_message: blocked_user.status_message().unwrap_or_default(),
                            relationship: relationship,
                            user_image: cx.render(rsx! (
                                UserImage {
                                    platform: platform,
                                    status: blocked_user.identity_status().into(),
                                    image: blocked_user.profile_picture()
                                }
                            )),
                            onremove: move |_| {
                                if STATIC_ARGS.use_mock {
                                    state.write().mutate(Action::Unblock(&unblock_user_clone.did_key()));
                                } else {
                                    ch.send(unblock_user_clone.clone().did_key());
                                }
                            }
                        }
                    }
                )
            })
        }
    ))
}
