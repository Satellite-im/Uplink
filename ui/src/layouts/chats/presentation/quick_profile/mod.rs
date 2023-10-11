use dioxus::{html::input_data::keyboard_types::Code, prelude::*};

use dioxus_router::prelude::use_navigator;
use futures::{channel::oneshot, StreamExt};

use kit::{
    components::context_menu::{ContextItem, ContextMenu, IdentityHeader},
    elements::{input::Input, range::Range},
};

use common::{
    icons::outline::Shape as Icon,
    warp_runner::{BlinkCmd, MultiPassCmd},
};
use common::{
    state::{Action, Chat, State},
    warp_runner::{RayGunCmd, WarpCmd},
    WARP_CMD_CH,
};

use common::language::get_local_text;

use uuid::Uuid;
use warp::{crypto::DID, logging::tracing::log};

use crate::UplinkRoute;

pub const USER_VOL_MIN: f32 = 0.25;
pub const USER_VOL_MAX: f32 = 5.0;

#[derive(Props)]
pub struct QuickProfileProps<'a> {
    id: &'a String,
    did_key: DID,
    update_script: &'a UseState<String>,
    children: Element<'a>,
}

#[allow(clippy::large_enum_variant)]
enum QuickProfileCmd {
    CreateConversation(Option<Chat>, DID),
    RemoveFriend(DID),
    BlockFriend(DID),
    UnBlockFriend(DID),
    RemoveDirectConvs(DID),
    Chat(Option<Chat>, Vec<String>, Option<Uuid>),
    AdjustVolume(DID, f32),
}

// Create a quick profile context menu
#[allow(non_snake_case)]
pub fn QuickProfileContext<'a>(cx: Scope<'a, QuickProfileProps<'a>>) -> Element<'a> {
    let state = use_shared_state::<State>(cx)?;
    let id = cx.props.id;

    let identity = state
        .read()
        .get_identity(&cx.props.did_key)
        .unwrap_or_default();
    let remove_identity = identity.clone();
    let block_identity = identity.clone();

    let did = &identity.did_key();
    let did_cloned = did.clone();
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
                _ = eval(script);
            }
        }
    });

    let is_self = state.read().get_own_identity().did_key().eq(did);
    let is_friend = state.read().has_friend_with_did(did);
    let blocked = state.read().is_blocked(did);
    let volume = state
        .read()
        .settings
        .user_volumes
        .get(did)
        .cloned()
        .unwrap_or(1.0);

    let router = use_navigator(cx);

    let chat_with: &UseState<Option<Uuid>> = use_state(cx, || None);
    if let Some(id) = *chat_with.get() {
        chat_with.set(None);
        state.write().mutate(Action::ChatWith(&id, true));
        if state.read().ui.is_minimal_view() {
            state.write().mutate(Action::SidebarHidden(true));
        }
        router.replace(UplinkRoute::ChatLayout {});
    }

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<QuickProfileCmd>| {
        to_owned![chat_with, state];
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
                    QuickProfileCmd::UnBlockFriend(did) => {
                        let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();
                        if let Err(e) = warp_cmd_tx
                            .send(WarpCmd::MultiPass(MultiPassCmd::Unblock { did, rsp: tx }))
                        {
                            log::error!("failed to send warp command: {}", e);
                            continue;
                        }

                        let rsp = rx.await.expect("command canceled");
                        if let Err(e) = rsp {
                            // todo: display message to user
                            log::error!("failed to unblock friend: {}", e);
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
                    QuickProfileCmd::Chat(chat, msg, uuid) => {
                        let c = match chat {
                            Some(c) => c.id,
                            None => return,
                        };
                        let msg_vec = msg.clone();
                        let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();
                        let cmd = RayGunCmd::SendMessage {
                            conv_id: c,
                            msg,
                            attachments: Vec::new(),
                            ui_msg_id: uuid,
                            rsp: tx,
                        };
                        if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(cmd)) {
                            log::error!("failed to send warp command: {}", e);
                            state
                                .write_silent()
                                .decrement_outgoing_messagess(c, msg_vec, uuid);
                            continue;
                        }

                        let rsp = rx.await.expect("command canceled");
                        if let Err(e) = rsp {
                            log::error!("failed to send message: {}", e);
                            state
                                .write_silent()
                                .decrement_outgoing_messagess(c, msg_vec, uuid);
                        }
                        chat_with.set(Some(c));
                    }
                    QuickProfileCmd::AdjustVolume(user, volume) => {
                        let (tx, rx) = oneshot::channel();
                        if let Err(e) = warp_cmd_tx.send(WarpCmd::Blink(BlinkCmd::AdjustVolume {
                            user: user.clone(),
                            volume,
                            rsp: tx,
                        })) {
                            log::error!("failed to send blink command: {e}");
                            continue;
                        }

                        match rx.await {
                            Ok(_) => {
                                state
                                    .write_silent()
                                    .settings
                                    .user_volumes
                                    .insert(user, volume);
                            }
                            Err(e) => {
                                log::error!("warp_runner failed to unmute self: {e}");
                            }
                        }
                    }
                }
            }
        }
    });

    cx.render(rsx!(ContextMenu {
        id: format!("{id}"),
        items: cx.render(rsx!(
            IdentityHeader {
                sender_did: identity.did_key()
            },
            div {
                id: "profile-name",
                aria_label: "profile-name",
                p {
                    class: "text",
                    aria_label: "profile-name-value",
                    format!("{}", identity.username())
                }
            }
            identity.status_message().and_then(|s|{
                cx.render(rsx!(
                    div {
                        id: "profile-status",
                        aria_label: "profile-status",
                        p {
                            class: "text",
                            aria_label: "profile-status-value",
                            s
                        }
                    }
                ))
            }),
            div {
                class: "profile-context-items",
                if is_self {
                    rsx!(hr{},
                        ContextItem {
                        icon: Icon::UserCircle,
                        aria_label: "quick-profile-self-edit".into(),
                        text: get_local_text("quickprofile.self-edit"),
                        onpress: move |_| {
                            router.replace(UplinkRoute::SettingsLayout {});
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
                                    aria_label: "quick-profile-message".into(),
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
                    if state.read().configuration.developer.experimental_features {
                        rsx!(
                            Range {
                                aria_label: "range-quick-profile-speaker".into(),
                                initial_value: volume,
                                min: USER_VOL_MIN,
                                max: USER_VOL_MAX,
                                step: 0.1,
                                no_num: true,
                                icon_left: Icon::Speaker,
                                icon_right: Icon::SpeakerWave,
                                onchange: move |val| {
                                    ch.send(QuickProfileCmd::AdjustVolume(did_cloned.clone(), val));
                                }
                            }
                        )
                    }
                    hr{},
                    if is_friend {
                        rsx!(ContextItem {
                            icon: Icon::UserMinus,
                            text: get_local_text("quickprofile.friend-remove"),
                            aria_label: "quick-profile-friend-remove".into(),
                            onpress: move |_| {
                                ch.send(QuickProfileCmd::RemoveFriend(remove_identity.did_key()));
                                ch.send(QuickProfileCmd::RemoveDirectConvs(remove_identity.did_key()));
                            }
                        })
                    }
                    ContextItem {
                        icon: if blocked {Icon::UserBlocked} else {Icon::UserBlock},
                        aria_label: if blocked {"quick-profile-unblock".into()} else {"quick-profile-block".into()},
                        text: if blocked {get_local_text("quickprofile.unblock")} else {get_local_text("quickprofile.block")},
                        onpress: move |_| {
                            if blocked {
                                ch.send(QuickProfileCmd::UnBlockFriend(block_identity.did_key()));
                            } else {
                                ch.send(QuickProfileCmd::BlockFriend(block_identity.did_key()));
                                ch.send(QuickProfileCmd::RemoveDirectConvs(block_identity.did_key()));
                            }
                        }
                    },
                    if is_friend && !chat_is_current {
                        rsx!(
                            hr{},
                            Input {
                                placeholder: get_local_text("quickprofile.chat-placeholder"),
                                onreturn: move |(val, _,_): (String,bool,Code)|{
                                    let ui_id = state
                                        .write_silent()
                                        .increment_outgoing_messages(vec![val.clone()], &[]);
                                    ch.send(QuickProfileCmd::Chat(chat_send.to_owned(), vec![val], ui_id));
                                }
                            }
                        )
                    })
                }
            }
        ))
        ,
        &cx.props.children
    }))
}
