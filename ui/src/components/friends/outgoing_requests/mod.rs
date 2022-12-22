use chrono::{Utc, Duration};
use dioxus::prelude::*;
use kit::{elements::label::Label, components::{context_menu::{ContextMenu, ContextItem}, user_image::UserImage, indicator::{Platform, Status}}, icons::Icon};
use rand::Rng;

use crate::{state::{State, Action}, utils::language::get_local_text, components::friends::friend::{Friend, Relationship}};

#[allow(non_snake_case)]
pub fn OutgoingRequests(cx: Scope) -> Element {
    let state: UseSharedState<State> = use_context::<State>(&cx).unwrap();
    let friends_list = state.read().friends.outgoing_requests.clone();

    cx.render(rsx! (
        div {
            class: "friends-list",
            Label {
                text: get_local_text("friends.outgoing_requests"),
            },
            friends_list.into_iter().map(|friend| {
                let did = friend.did_key().clone();
                let did_suffix: String = did.to_string().chars().rev().take(6).collect();
                let mut rng = rand::thread_rng();
                let friend_clone = friend.clone();
                let friend_clone_clone = friend.clone();

                rsx!(
                    ContextMenu {
                        id: format!("{}-friend-listing", did),
                        key: "{did}-friend-listing",
                        items: cx.render(rsx!(
                            ContextItem {
                                danger: true,
                                icon: Icon::XMark,
                                text: get_local_text("friends.cancel"),
                                onpress: move |_| {
                                    let _ = &state.write().mutate(Action::CancelRequest(friend_clone_clone.clone()));
                                }
                            },
                        )),
                        Friend {
                            username: friend.username(),
                            suffix: did_suffix,
                            status_message: friend.status_message().unwrap_or_default(), 
                            relationship: Relationship {
                                friends: false,
                                received_friend_request: false,
                                sent_friend_request: true,
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
                            onremove: move |_| {
                                let _ = &state.write().mutate(Action::CancelRequest(friend_clone.clone()));
                            }
                        }
                    }
                )
            })
        }
    ))
}