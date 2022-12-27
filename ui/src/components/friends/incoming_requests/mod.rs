use chrono::{Utc, Duration};
use dioxus::prelude::*;
use kit::{elements::label::Label, components::{context_menu::{ContextMenu, ContextItem}, user_image::UserImage, indicator::{Platform, Status}}, icons::Icon};
use rand::Rng;

use crate::{state::{State, Action}, utils::language::get_local_text, components::friends::friend::{Friend, Relationship}};

#[allow(non_snake_case)]
pub fn PendingFriends(cx: Scope) -> Element {
    let state: UseSharedState<State> = use_shared_state::<State>(&cx).unwrap();
    let friends_list = state.read().friends.incoming_requests.clone();

    cx.render(rsx! (
        div {
            class: "friends-list",
            Label {
                text: get_local_text("friends.incoming_requests"),
            },
            friends_list.into_iter().map(|friend| {
                let mut rng = rand::thread_rng();
                let did = friend.did_key();
                let did_suffix: String = did.to_string().chars().rev().take(6).collect();
                let friend_clone = friend.clone();
                let friend_clone_clone = friend.clone();
                let friend_clone_clone_clone = friend.clone();
            
                rsx!(
                    ContextMenu {
                        id: format!("{}-friend-listing", did),
                        key: "{did}-friend-listing",
                        items: cx.render(rsx!(
                            ContextItem {
                                danger: true,
                                icon: Icon::XMark,
                                text: get_local_text("friends.deny"),
                                onpress: move |_| {
                                    state.write().mutate(Action::DenyRequest(friend_clone_clone_clone.clone()));
                                }
                            },
                        )),
                        Friend {
                            username: friend.username(),
                            suffix: did_suffix,
                            status_message: friend.status_message().unwrap_or_default(), 
                            relationship: Relationship {
                                friends: false,
                                received_friend_request: true,
                                sent_friend_request: false,
                                blocked: false,
                            },
                            request_datetime: Utc::now() - Duration::days(rng.gen_range(0..30)),
                            user_image: cx.render(rsx! (
                                UserImage {
                                    platform: Platform::Desktop,
                                    status: Status::Online,
                                    image: friend.graphics().profile_picture()
                                }
                            )),
                            onaccept: move |_| {
                                state.write().mutate(Action::AcceptRequest(friend_clone.clone()));
                            },
                            onremove: move |_| {
                               state.write().mutate(Action::DenyRequest(friend_clone_clone.clone()));
                            }
                        }
                    }
                )
            })
        }
    ))
}