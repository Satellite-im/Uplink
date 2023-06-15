use std::collections::{BTreeMap, HashMap};

use common::{
    icons::outline::Shape as Icon,
    language::get_local_text,
    state::{Chat, Identity, State},
};
use dioxus::prelude::*;

use kit::{
    components::user_image::UserImage,
    elements::input::{Input, Options},
};
use warp::logging::tracing::log;

#[derive(Props, Eq, PartialEq)]
pub struct Props {
    #[props(!optional)]
    active_chat: Option<Chat>,
}

#[allow(non_snake_case)]

pub fn GroupUsers(cx: Scope<Props>) -> Element {
    log::trace!("rendering group_users");
    let state = use_shared_state::<State>(cx)?;
    let friend_prefix = use_state(cx, String::new);

    let active_chat = match cx.props.active_chat.as_ref() {
        Some(r) => r,
        None => return cx.render(rsx!(div {})),
    };
    if active_chat.participants.is_empty() {
        return cx.render(rsx!(div {}));
    }

    let participant_dids = Vec::from_iter(active_chat.participants.iter().cloned());
    let group_participants = state.read().get_identities(&participant_dids);
    let hash_map = HashMap::from_iter(
        group_participants
            .iter()
            .map(|ident| (ident.did_key(), ident.clone())),
    );
    let _friends_in_group = State::get_friends_by_first_letter(hash_map);

    cx.render(rsx!(
        div {
            id: "group-users",
            aria_label: "group-users",
            div {
                class: "search-input",
                Input {
                    // todo: filter friends on input
                    placeholder: get_local_text("uplink.search-placeholder"),
                    disabled: false,
                    aria_label: "friend-search-input".into(),
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
                    friends: _friends_in_group,
                    name_prefix: friend_prefix.clone(),
                },
        }
    ))
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
            aria_label: "friends-list",
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
                    aria_label: "friend-username",
                    cx.props.friend.username(),
                },
            },
        }
    ))
}
