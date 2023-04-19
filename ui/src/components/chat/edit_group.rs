use std::collections::{BTreeMap, HashMap, HashSet};

use common::{
    icons::outline::Shape as Icon,
    language::get_local_text,
    state::{Identity, State},
    warp_runner::{RayGunCmd, WarpCmd},
    WARP_CMD_CH,
};
use dioxus::prelude::*;
use futures::{channel::oneshot, StreamExt};
use kit::{
    components::user_image::UserImage,
    elements::{
        button::Button,
        checkbox::Checkbox,
        input::{Input, Options},
        Appearance,
    },
    layout::topbar::Topbar,
};
use warp::{crypto::DID, logging::tracing::log};

#[derive(PartialEq, Clone)]
enum EditGroupAction {
    Add,
    Remove,
}

enum ChanCmd {
    AddParticipants,
    RemoveParticipants,
}

#[derive(Props)]
pub struct Props<'a> {
    onedit: EventHandler<'a, MouseEvent>,
}

#[allow(non_snake_case)]
pub fn EditGroup<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    log::trace!("rendering edit_group");
    let state = use_shared_state::<State>(cx)?;
    let friend_prefix = use_state(cx, String::new);
    let selected_friends: &UseState<HashSet<DID>> = use_state(cx, HashSet::new);
    let edit_group_action = use_state(cx, || EditGroupAction::Add);
    let conv_id = state.read().get_active_chat().unwrap().id;
    let friends_did_already_in_group = state.read().get_active_chat().unwrap().participants;
    let friends_list = HashMap::from_iter(
        state
            .read()
            .friend_identities()
            .iter()
            .map(|id| (id.did_key(), id.clone())),
    );
    let mut friends_group_list = friends_list.clone();
    let mut friends_not_in_group_list = friends_list;

    friends_group_list.retain(|did_key, _| friends_did_already_in_group.contains(did_key));
    friends_not_in_group_list.retain(|did_key, _| !friends_did_already_in_group.contains(did_key));

    let _friends_not_in_group = State::get_friends_by_first_letter(friends_not_in_group_list);
    let _friends_in_group = State::get_friends_by_first_letter(friends_group_list);

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<ChanCmd>| {
        to_owned![selected_friends, conv_id];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(cmd) = rx.next().await {
                match cmd {
                    ChanCmd::AddParticipants => {
                        let recipients: Vec<DID> =
                            selected_friends.current().iter().cloned().collect();
                        let (tx, rx) = oneshot::channel();
                        if let Err(e) =
                            warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::AddGroupParticipants {
                                conv_id,
                                recipients,
                                rsp: tx,
                            }))
                        {
                            log::error!("failed to send warp command: {}", e);
                            continue;
                        }
                        let res = rx.await.expect("command canceled");
                        if let Err(e) = res {
                            log::error!("failed to add new recipients to a group: {}", e);
                        }
                    }
                    ChanCmd::RemoveParticipants => {
                        let recipients: Vec<DID> =
                            selected_friends.current().iter().cloned().collect();
                        let (tx, rx) = oneshot::channel();
                        if let Err(e) =
                            warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::RemoveGroupParticipants {
                                conv_id,
                                recipients,
                                rsp: tx,
                            }))
                        {
                            log::error!("failed to send warp command: {}", e);
                            continue;
                        }
                        let res = rx.await.expect("command canceled");
                        if let Err(e) = res {
                            log::error!("failed to remove recipients from a group: {}", e);
                        }
                    }
                }
            }
        }
    });

    let add_friends_with_sidebar = rsx!(div {
        id: "edit-group-add-friends-button-with_sidebar",
        key: "edit-group-add-friends-button-with_sidebar",
        Button {
            icon: Icon::UserPlus,
            text: get_local_text("uplink.add"),
            aria_label: "edit-group-add-friends-button-with_sidebar".into(),
            appearance: if *edit_group_action.get() == EditGroupAction::Add {
                Appearance::Primary
            } else {
                Appearance::Secondary
            },
            onpress: move |_| {
                edit_group_action.set(EditGroupAction::Add);
            }
        }
    });

    let add_friends_without_sidebar = rsx!(div {
        id: "edit-group-add-friends-button-without-sidebar",
        width: "38px",
        key: "edit-group-add-friends-button-without-sidebar",
        Button {
            icon: Icon::UserPlus,
            text: "".into(),
            aria_label: "edit-group-add-friends-button-without-sidebar".into(),
            appearance: if *edit_group_action.get() == EditGroupAction::Add {
                Appearance::Primary
            } else {
                Appearance::Secondary
            },
            onpress: move |_| {
                edit_group_action.set(EditGroupAction::Add);
            }
        }
    });

    let remove_friends_with_sidebar = rsx!(div {
        id: "edit-group-remove_friends_with_sidebar",
        key: "edit-group-remove_friends_with_sidebar",
        Button {
            icon: Icon::UserPlus,
            text: get_local_text("uplink.remove"),
            aria_label: "edit-group-remove_friends_with_sidebar".into(),
            appearance: if *edit_group_action.get() == EditGroupAction::Remove {
                Appearance::Primary
            } else {
                Appearance::Secondary
            },
            onpress: move |_| {
                edit_group_action.set(EditGroupAction::Remove);
            }
        }
    });

    let remove_friends_without_sidebar = rsx!(div {
        id: "edit-group-remove-friends-without-sidebar",
        width: "38px",
        key: "edit-group-remove-friends-without-sidebar",
        Button {
            icon: Icon::UserPlus,
            text: "".into(),
            aria_label: "edit-group-remove-friends-without-sidebar".into(),
            appearance: if *edit_group_action.get() == EditGroupAction::Remove {
                Appearance::Primary
            } else {
                Appearance::Secondary
            },
            onpress: move |_| {
                edit_group_action.set(EditGroupAction::Remove);
            }
        }
    });

    cx.render(rsx!(
        div {
            id: "edit-group",
            aria_label: "edit-group",
            Topbar {
                with_back_button: false,
                controls: cx.render(rsx!(
                    if state.read().ui.sidebar_hidden {
                       rsx! {
                        add_friends_without_sidebar,
                        remove_friends_without_sidebar,
                       }
                    } else {
                        rsx! {
                            add_friends_with_sidebar,
                            remove_friends_with_sidebar,
                        }
                    },
                )),
            },
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
            div {
                key: "render_friends",
                render_friends {
                    friends: if *edit_group_action.get() == EditGroupAction::Add {_friends_not_in_group} else {_friends_in_group},
                    name_prefix: friend_prefix.clone(),
                    selected_friends: selected_friends.clone()
                },
            }
            if *edit_group_action.current() == EditGroupAction::Add {
                rsx!(
                    div {
                        key: "add-button",
                        Button {
                            text: get_local_text("uplink.add"),
                            appearance: Appearance::Primary,
                            onpress: move |e| {
                                log::info!("add participants button");
                                ch.send(ChanCmd::AddParticipants);
                                cx.props.onedit.call(e);
                            }
                        }
                    }
                )
            } else {
                rsx!(
                    div {
                        key: "remove-button",
                        Button {
                            text: get_local_text("uplink.remove"),
                            appearance: Appearance::Primary,
                            onpress: move |e| {
                                log::info!("remove participants button");
                                ch.send(ChanCmd::RemoveParticipants);
                                cx.props.onedit.call(e);
                            }
                        }
                    }
                )
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
