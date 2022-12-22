use dioxus::prelude::*;
use kit::{elements::label::Label, components::{context_menu::{ContextMenu, ContextItem}, user_image::UserImage, indicator::{Platform, Status}}, icons::Icon};

use crate::{state::{State, Action}, utils::language::get_local_text, components::friends::friend::{Friend, Relationship}};

#[allow(non_snake_case)]
pub fn BlockedUsers(cx: Scope) -> Element {
    let state: UseSharedState<State> = use_context::<State>(&cx).unwrap();
    let block_list = state.read().friends.blocked.clone();

    cx.render(rsx! (
        div {
            class: "friends-list",
            Label {
                text: get_local_text("friends.blocked"),
            },
            block_list.into_iter().map(|blocked_user| {
                let did = blocked_user.did_key().clone();
                let did_suffix: String = did.to_string().chars().rev().take(6).collect();
                let unblock_user = blocked_user.clone();
                let unblock_user_clone = unblock_user.clone();

                rsx!(
                    ContextMenu {
                        id: format!("{}-friend-listing", did),
                        key: "{did}-friend-listing",
                        items: cx.render(rsx!(
                            ContextItem {
                                danger: true,
                                icon: Icon::XMark,
                                text: get_local_text("friends.unblock"),
                                onpress: move |_| {
                                    state.write().mutate(Action::UnBlock(unblock_user.clone()));
                                }
                            },
                        )),
                        Friend {
                            username: blocked_user.username(),
                            suffix: did_suffix,
                            status_message: blocked_user.status_message().unwrap_or_default(), 
                            relationship: Relationship {
                                friends: false,
                                received_friend_request: false,
                                sent_friend_request: false,
                                blocked: true,
                            },
                            user_image: cx.render(rsx! (
                                UserImage {
                                    platform: Platform::Desktop,
                                    status: Status::Online,
                                    image: blocked_user.graphics().profile_picture()
                                }
                            )),
                            onremove: move |_| {
                                state.write().mutate(Action::UnBlock(unblock_user_clone.clone()));
                            }
                        }
                    }
                )
            })
        }
    ))
}
