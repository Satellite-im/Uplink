use dioxus::prelude::*;

use dioxus_router::use_router;
use futures::{channel::oneshot, StreamExt};

use kit::{
    components::context_menu::{ContextItem, ContextMenu, IdentityHeader},
    elements::input::Input,
};

use common::{icons::outline::Shape as Icon, warp_runner::MultiPassCmd};
use common::{
    state::{Action, Chat, Identity, State},
    warp_runner::{RayGunCmd, WarpCmd},
    WARP_CMD_CH,
};

use common::language::get_local_text;
use dioxus_desktop::use_eval;

#[cfg(target_os = "windows")]
use tokio::time::sleep;
use uuid::Uuid;
use warp::{crypto::DID, logging::tracing::log};

use crate::UPLINK_ROUTES;

#[derive(Props)]
pub struct QuickProfileProps<'a> {
    id: &'a String,
    identity: &'a UseState<Identity>,
    update_script: &'a UseState<String>,
    children: Element<'a>,
}

#[allow(clippy::large_enum_variant)]
enum QuickProfileCmd {
    CreateConversation(Option<Chat>, DID),
    RemoveFriend(DID),
    BlockFriend(DID),
    RemoveDirectConvs(DID),
    Chat(Option<Chat>, String),
}

// Create a quick profile context menu
#[allow(non_snake_case)]
pub fn QuickProfileContext<'a>(cx: Scope<'a, QuickProfileProps<'a>>) -> Element<'a> {
    let state = use_shared_state::<State>(cx)?;
    let id = cx.props.id;

    let identity = cx.props.identity.get();
    let remove_identity = identity.clone();
    let block_identity = identity.clone();

    let did = &identity.did_key();
    let chat_of = state.read().get_chat_with_friend(identity.did_key());
    let chat_send = chat_of.clone();

    let chat_is_current = match state.read().get_active_chat() {
        Some(c) => match &chat_of {
            Some(cO) => c.eq(cO),
            None => false,
        },
        None => false,
    };

    let eval = use_eval(cx);
    use_future(cx, cx.props.update_script, |update_script| {
        to_owned![eval];
        async move {
            let script = update_script.get();
            if !script.is_empty() {
                eval(script.to_string());
            }
        }
    });

    let is_self = state.read().get_own_identity().did_key().eq(did);
    let is_friend = state.read().has_friend_with_did(did);

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

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<QuickProfileCmd>| {
        to_owned![chat_with];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(cmd) = rx.next().await {
                match cmd {
                    QuickProfileCmd::CreateConversation(chat, did) => {
                        // verify chat exists
                        let chat = match chat {
                            Some(c) => c.id,
                            None => {
                                // if not, create the chat
                                let (tx, rx) = oneshot::channel();
                                if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(
                                    RayGunCmd::CreateConversation {
                                        recipient: did,
                                        rsp: tx,
                                    },
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
                    QuickProfileCmd::RemoveFriend(did) => {
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
                    QuickProfileCmd::BlockFriend(did) => {
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
                    QuickProfileCmd::RemoveDirectConvs(recipient) => {
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
                    QuickProfileCmd::Chat(chat, msg) => {
                        let c = match chat {
                            Some(c) => c.id,
                            None => return,
                        };
                        let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();
                        let cmd = RayGunCmd::SendMessage {
                            conv_id: c,
                            msg: vec![msg],
                            attachments: Vec::new(),
                            rsp: tx,
                        };
                        if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(cmd)) {
                            log::error!("failed to send warp command: {}", e);
                            continue;
                        }

                        let rsp = rx.await.expect("command canceled");
                        if let Err(e) = rsp {
                            log::error!("failed to send message: {}", e);
                        }
                        chat_with.set(Some(c));
                    }
                }
            }
        }
    });

    cx.render(rsx!(ContextMenu {
        id: format!("{id}"),
        items: cx.render(rsx!(
            IdentityHeader {
                identity: identity
            },
            hr{},
            div {
                id: "profile-name",
                aria_label: "profile-name",
                p {
                    class: "text",
                    aria_label: "profile-name-value",
                    "{cx.props.identity.username()}"
                }
            }
            identity.status_message().and_then(|s|{
                cx.render(rsx!(
                    hr{},
                    div {
                        id: "profile-status",
                        aria_label: "profile-status",
                        p {
                            class: "text bold",
                            aria_label: "profile-status-header",
                            get_local_text("uplink.status")
                        },
                        hr {},
                        p {
                            class: "text",
                            aria_label: "profile-status-value",
                            s
                        }
                    }
                ))
            }),
            hr{},
            if is_self {
                rsx!(ContextItem {
                    icon: Icon::UserCircle,
                    text: get_local_text("quickprofile.self-edit"),
                    onpress: move |_| {
                        router.replace_route(UPLINK_ROUTES.settings, None, None);
                    }
                })
            } else {
                rsx!(
                    /*ContextItem {
                    icon: Icon::UserCircle,
                    text: get_local_text("quickprofile.profile"),
                    // TODO: Show a profile popup
                },*/
                if is_friend {
                    rsx!(
                        if !chat_is_current {
                            rsx!(
                                ContextItem {
                                icon: Icon::ChatBubbleBottomCenterText,
                                text: get_local_text("quickprofile.message"),
                                onpress: move |_| {
                                    ch.send(QuickProfileCmd::CreateConversation(chat_of.clone(), identity.did_key()));
                                }
                            })
                        }
                        /*ContextItem {
                            icon: Icon::PhoneArrowUpRight,
                            text: get_local_text("quickprofile.call"),
                            // TODO: Impl missing
                        }*/
                    )
                }
                hr{},
                if is_friend {
                    rsx!(ContextItem {
                        icon: Icon::UserMinus,
                        text: get_local_text("quickprofile.friend-remove"),
                        onpress: move |_| {
                            ch.send(QuickProfileCmd::RemoveFriend(remove_identity.did_key()));
                            ch.send(QuickProfileCmd::RemoveDirectConvs(remove_identity.did_key()));
                        }
                    })
                }
                ContextItem {
                    icon: Icon::UserBlock,
                    text: get_local_text("quickprofile.block"),
                    onpress: move |_| {
                        ch.send(QuickProfileCmd::BlockFriend(block_identity.did_key()));
                        ch.send(QuickProfileCmd::RemoveDirectConvs(block_identity.did_key()));
                    }
                },
                if is_friend && !chat_is_current {
                    rsx!(
                        hr{},
                        Input {
                            placeholder: get_local_text("quickprofile.chat-placeholder"),
                            onreturn: move |(val, _,_)|{
                                ch.send(QuickProfileCmd::Chat(chat_send.to_owned(), val));
                            }
                        }
                    )
                })
            }
        ))
        ,
        &cx.props.children
    }))
}
