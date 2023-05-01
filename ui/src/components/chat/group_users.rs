use std::collections::{BTreeMap, HashMap, HashSet};

use common::{
    icons::outline::Shape as Icon,
    language::get_local_text,
    state::{Identity, State},
};
use dioxus::prelude::*;
use kit::{
    components::user_image::UserImage,
    elements::{
        input::{Input, Options},
        label::Label,
    },
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
    UpdateGroupName(String),
}

#[derive(Props)]
pub struct Props<'a> {
    onedit: EventHandler<'a, MouseEvent>,
}

#[allow(non_snake_case)]
pub fn GroupUsers<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
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
    friends_group_list.retain(|did_key, _| friends_did_already_in_group.contains(did_key));
    let _friends_in_group = State::get_friends_by_first_letter(friends_group_list);

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
                    selected_friends: selected_friends.clone()
                },
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
    cx.render(rsx!(
        div {
            class: "friend-container",
            aria_label: "Friend Container",
            UserImage {
                platform: cx.props.friend.platform().into(),
                status: cx.props.friend.identity_status().into(),
                image: cx.props.friend.profile_picture()
                on_press: move |_| {
                },
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
