use std::{
    cell::RefCell,
    collections::{HashMap, HashSet},
    rc::Rc,
};

use common::{icons::outline::Shape as Icon, language::get_local_text, state::State};
use dioxus::prelude::*;
use dioxus_router::*;
use kit::{
    components::user_image::UserImage,
    elements::{
        input::{Input, Options},
        label::Label,
    },
};
use warp::{crypto::DID, logging::tracing::log};

#[derive(PartialEq, Props)]
pub struct Props {}

pub fn create_group(cx: Scope<Props>) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let selected_friends: Rc<RefCell<HashSet<DID>>> = Rc::new(RefCell::new(HashSet::new()));
    let friends_list = HashMap::from_iter(
        state
            .read()
            .friend_identities()
            .iter()
            .map(|id| (id.did_key(), id.clone())),
    );
    let friends = State::get_friends_by_first_letter(friends_list);
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
                        ..Options::default()
                    }
                }
            }
            Label {
                text: get_local_text("friends.friends"),
            },
            friends.into_iter().map(|(letter, sorted_friends)| {
                let group_letter = letter.to_string();
                // todo: put this in another function
                rsx!(
                    div {
                        key: "friend-group-{group_letter}",
                        sorted_friends.into_iter().map(|friend| {rsx!(
                            div {
                                class: "friend-container",
                                aria_label: "Friend Container",
                                onclick: move |_| {
                                    log::info!("clicked row");
                                },
                                UserImage {
                                    platform: friend.platform().into(),
                                    status: friend.identity_status().into(),
                                    image: friend.graphics().profile_picture()
                                    onpress: move |_| {
                                        log::info!("clicked userimage");
                                    },
                                },
                                p {
                                    friend.username(),
                                },
                                input {
                                    id: "select-friend-{friend.did_key()}",
                                    class: "select-friend",
                                    "type": "checkbox",
                                    disabled: false,
                                    //checked: false,
                                    oninput: move |_| {
                                        log::info!("input checkbox");
                                    },
                                    onclick: move |_| {
                                        log::info!("clicked checkbox");
                                    },
                                }
                            }
                        )})
                    }
                )
            }),
        }
    ))
}

//#[inline_props]
//fn render_friend(cx: Scope, friend: Identity) -> Element {}
