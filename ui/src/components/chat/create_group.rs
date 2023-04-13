use std::collections::{BTreeMap, HashMap, HashSet};

use common::{
    icons::outline::Shape as Icon,
    language::get_local_text,
    state::{Action, Identity, State},
    warp_runner::{RayGunCmd, WarpCmd},
    WARP_CMD_CH,
};
use dioxus::prelude::*;
use dioxus_router::*;
use futures::{channel::oneshot, StreamExt};
use kit::{
    components::user_image::UserImage,
    elements::{
        button::Button,
        checkbox::Checkbox,
        input::{Input, Options},
        Appearance,
    },
};
use uuid::Uuid;
use warp::{crypto::DID, logging::tracing::log};

use crate::UPLINK_ROUTES;

#[derive(Props)]
pub struct Props<'a> {
    oncreate: EventHandler<'a, MouseEvent>,
}

#[allow(non_snake_case)]
pub fn CreateGroup<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    log::trace!("rendering create_group");
    let state = use_shared_state::<State>(cx)?;
    let router = use_router(cx);
    let friend_prefix = use_state(cx, String::new);
    let selected_friends: &UseState<HashSet<DID>> = use_state(cx, HashSet::new);
    let chat_with: &UseState<Option<Uuid>> = use_state(cx, || None);
    let friends_list = HashMap::from_iter(
        state
            .read()
            .friend_identities()
            .iter()
            .map(|id| (id.did_key(), id.clone())),
    );

    if let Some(id) = *chat_with.get() {
        chat_with.set(None);
        state.write().mutate(Action::ChatWith(&id, true));
        if state.read().ui.is_minimal_view() {
            state.write().mutate(Action::SidebarHidden(true));
        }
        router.replace_route(UPLINK_ROUTES.chat, None, None);
    }

    let _friends = State::get_friends_by_first_letter(friends_list);

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<()>| {
        to_owned![selected_friends, chat_with];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while rx.next().await.is_some() {
                let recipients: Vec<DID> = selected_friends.current().iter().cloned().collect();

                let (tx, rx) = oneshot::channel();
                let cmd = match &recipients[..] {
                    [] => continue,
                    [recipient] => RayGunCmd::CreateConversation {
                        recipient: recipient.clone(),
                        rsp: tx,
                    },
                    _ => RayGunCmd::CreateGroupConversation {
                        recipients,
                        rsp: tx,
                    },
                };

                if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(cmd)) {
                    log::error!("failed to send warp command: {}", e);
                    continue;
                }

                let rsp = rx.await.expect("command canceled");

                let id = match rsp {
                    Ok(c) => c,
                    Err(e) => {
                        log::error!("failed to create conversation: {}", e);
                        continue;
                    }
                };
                chat_with.set(Some(id));
            }
        }
    });

    cx.render(rsx!(
        div {
            id: "create-group",
            aria_label: "Create Group",
            div {
                class: "search-input",
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
            render_friends {
                friends: _friends,
                name_prefix: friend_prefix.clone(),
                selected_friends: selected_friends.clone()
            },
            Button {
                text: "Create DM".into(),
                appearance: Appearance::Primary,
                onpress: move |e| {
                    log::info!("create dm button");
                    ch.send(());
                    cx.props.oncreate.call(e);
                }
            }
        }
    ))
}

#[derive(PartialEq, Props)]
pub struct FriendsProps {
    friends: BTreeMap<char, Vec<Identity>>,
    name_prefix: UseState<String>,
    selected_friends: UseState<HashSet<DID>>,
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
                                    selected_friends: cx.props.selected_friends.clone()
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
    selected_friends: UseState<HashSet<DID>>,
}
fn render_friend(cx: Scope<FriendProps>) -> Element {
    let is_checked = use_state(cx, || false);
    if !*is_checked.current()
        && cx
            .props
            .selected_friends
            .current()
            .contains(&cx.props.friend.did_key())
    {
        is_checked.set(true);
    }

    let update_fn = || {
        let friend_did = cx.props.friend.did_key();
        let new_value = !*is_checked.get();
        is_checked.set(new_value);
        let mut friends = cx.props.selected_friends.get().clone();
        if new_value {
            friends.insert(friend_did);
        } else {
            friends.remove(&friend_did);
        }
        cx.props.selected_friends.set(friends);
    };

    cx.render(rsx!(
        div {
            class: "friend-container",
            aria_label: "Friend Container",
            UserImage {
                platform: cx.props.friend.platform().into(),
                status: cx.props.friend.identity_status().into(),
                image: cx.props.friend.profile_picture()
                on_press: move |_| {
                    update_fn();
                },
            },
            div {
                class: "flex-1",
                p {
                    onclick: move |_| {
                        update_fn();
                    },
                    cx.props.friend.username(),
                },
            },
            Checkbox{
                disabled: false,
                width: "1em".into(),
                height: "1em".into(),
                is_checked: *is_checked.get(),
                on_click: move |_| {
                    update_fn();
                }
            }
        }
    ))
}
