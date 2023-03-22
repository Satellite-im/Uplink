use std::collections::{BTreeMap, HashMap, HashSet};

use common::{
    icons::outline::Shape as Icon,
    language::get_local_text,
    state::{Identity, State},
};
use dioxus::prelude::*;
use dioxus_router::*;
use kit::{
    components::user_image::UserImage,
    elements::{
        button::Button,
        checkbox::Checkbox,
        input::{Input, Options},
        label::Label,
        Appearance,
    },
};
use warp::{crypto::DID, logging::tracing::log};

#[derive(PartialEq, Props)]
pub struct Props {}

pub fn create_group(cx: Scope<Props>) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let router = use_router(cx);
    let friend_prefix = use_state(cx, String::new);
    let selected_friends: &UseState<HashSet<DID>> = use_state(cx, HashSet::new);
    let friends_list = HashMap::from_iter(
        state
            .read()
            .friend_identities()
            .iter()
            .map(|id| (id.did_key(), id.clone())),
    );

    let _friends = State::get_friends_by_first_letter(friends_list);
    // todo: button to leave the view
    // todo: button to create the group chat
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
            Label {
                text: get_local_text("friends.friends"),
            },
            render_friends {
                friends: _friends,
                name_prefix: friend_prefix.clone(),
                selected_friends: selected_friends.clone()
            }
            div {
                class: "button-container",
                Button {
                    text: "Create DM".into(),
                    appearance: Appearance::Primary,
                    onpress: move |_| {
                        // todo
                    },
                }
                Button {
                    text: "Cancel".into(),
                    appearance: Appearance::Primary,
                    onpress: move |_| router.pop_route(),
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
                            sorted_friends.iter().filter(|friend| {
                                let name = friend.username();
                                if name.len() < name_prefix.len() {
                                    false
                                } else {
                                    &name[..(name_prefix.len())] == name_prefix
                                }
                            } ).map(|_friend| {
                                rsx!(
                                render_friend{
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

    let update_fn = || {
        if *is_checked.get() {
            cx.props
                .selected_friends
                .make_mut()
                .remove(&cx.props.friend.did_key());
        } else {
            cx.props
                .selected_friends
                .make_mut()
                .insert(cx.props.friend.did_key());
        }
    };

    cx.render(rsx!(
        div {
            class: "friend-container",
            aria_label: "Friend Container",
            onclick: move |_| {
                // for some reason this onclick event doesn't trigger when clicking the checkbox.
                // if it ever did, this event could be moved to a child element of this div
                is_checked.with_mut(|v| *v = !*v);
                update_fn();
            },
            UserImage {
                platform: cx.props.friend.platform().into(),
                status: cx.props.friend.identity_status().into(),
                image: cx.props.friend.graphics().profile_picture()
                on_press: move |_| {
                    is_checked.with_mut(|v| *v = !*v);
                    update_fn();
                },
            },
            p {
                cx.props.friend.username(),
            },
            Checkbox{
                disabled: false,
                width: "1em".into(),
                height: "1em".into(),
                is_checked: is_checked.clone(),
                on_click: move |_| {
                    update_fn();
                }
            }
        }
    ))
}
