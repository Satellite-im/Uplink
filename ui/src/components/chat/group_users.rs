use std::collections::{BTreeMap, HashMap};

use common::{
    icons::outline::Shape as Icon,
    language::get_local_text,
    state::{Identity, State},
    warp_runner::{MultiPassCmd, WarpCmd},
    WARP_CMD_CH,
};
use dioxus::prelude::*;
use futures::{channel::oneshot, StreamExt};
use kit::{
    components::user_image::UserImage,
    elements::{
        input::{Input, Options},
        label::Label,
    },
};
use warp::{crypto::DID, logging::tracing::log};

#[allow(non_snake_case)]
pub fn GroupUsers(cx: Scope) -> Element {
    log::trace!("rendering group_users");
    let state = use_shared_state::<State>(cx)?;
    let friend_prefix = use_state(cx, String::new);
    let conv_id = state.read().get_active_chat().unwrap().id;
    let friends_did_already_in_group = state.read().get_active_chat().unwrap().participants;
    let group_participants: &UseRef<HashMap<DID, Identity>> = use_ref(cx, HashMap::new);

    let _friends_in_group = State::get_friends_by_first_letter(group_participants.read().clone());

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<()>| {
        to_owned![friends_did_already_in_group, group_participants];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(cmd) = rx.next().await {
                let recipients: Vec<DID> = friends_did_already_in_group.iter().cloned().collect();
                let (tx, rx) = oneshot::channel();
                if let Err(e) = warp_cmd_tx.send(WarpCmd::MultiPass(MultiPassCmd::GetIdentities {
                    dids: recipients,
                    rsp: tx,
                })) {
                    log::error!("failed to send warp command: {}", e);
                    continue;
                }
                let res = rx.await.expect("command canceled");
                if let Ok(identities) = res {
                    group_participants.with_mut(|i| i.extend(identities.clone()));
                } else {
                    log::error!("failed to get identities for group");
                }
            }
        }
    });

    if group_participants.read().is_empty() {
        ch.send(());
        cx.render(rsx!(div {}))
    } else {
        cx.render(rsx!(
            div {
                id: "group-users",
                aria_label: "group-users",
                div {
                    class: "search-input",
                    Label {
                        text: format!("{} {}", _friends_in_group.len(),  get_local_text(
                            if _friends_in_group.len() > 1 {
                                "messages.participants"
                            } else {
                                "messages.participant"
                            }
                            )),
                    },
                    Input {
                        // todo: filter friends on input
                        placeholder: get_local_text("uplink.search-placeholder"),
                        disabled: false,
                        aria_label: "chat-search-input".into(),
                        icon: Icon::MagnifyingGlass,
                        options: Options {
                            with_clear_btn: true,
                            react_to_esc_key: true,
                            ..Options::default()
                        },
                        onchange: move |(v, _): (String, _)| {
                            friend_prefix.set(v);
                        },
                    }
                }
                div {
                    key: "render_friends",
                    render_friends {
                        friends: _friends_in_group,
                        name_prefix: friend_prefix.clone(),
                    },
                }
            }
        ))
    }
}

#[derive(PartialEq, Props)]
pub struct FriendsProps {
    friends: BTreeMap<char, Vec<Identity>>,
    name_prefix: UseState<String>,
}

fn render_friends(cx: Scope<FriendsProps>) -> Element {
    let name_prefix = cx.props.name_prefix.get();
    cx.render(rsx!(
        div {
            class: "friend-list vertically-scrollable",
            cx.props.friends.iter().map(
                |(letter, sorted_friends)| {
                    let group_letter = letter.to_string();
                    rsx!(
                        div {
                            key: "friend-group-{group_letter}",
                            class: "friend-group",
                            sorted_friends.iter().filter(|friend| {
                                let name = friend.username();
                                if name.len() < name_prefix.len() {
                                    false
                                } else {
                                    &name[..(name_prefix.len())] == name_prefix
                                }
                            } ).map(|_friend| {
                                rsx!(
                                render_friend {
                                    friend: _friend.clone(),
                                }
                            )})
                        }
                    )
                }
            ),
        }
    ))
}

#[derive(PartialEq, Props)]
pub struct FriendProps {
    friend: Identity,
}
fn render_friend(cx: Scope<FriendProps>) -> Element {
    cx.render(rsx!(
        div {
            class: "friend-container",
            aria_label: "Friend Container",
            UserImage {
                platform: cx.props.friend.platform().into(),
                status: cx.props.friend.identity_status().into(),
                image: cx.props.friend.profile_picture()
            },
            div {
                class: "flex-1",
                p {
                    cx.props.friend.username(),
                },
            },
        }
    ))
}
