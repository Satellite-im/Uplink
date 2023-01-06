use crate::{
    components::friends::friend::Friend,
    state::{Action, State},
};
use dioxus::prelude::*;
use kit::{
    components::{
        context_menu::{ContextItem, ContextMenu},
        indicator::{Platform, Status},
        user_image::UserImage,
    },
    elements::label::Label,
    icons::Icon,
};
use shared::language::get_local_text;
use warp::multipass::identity::Relationship;

#[allow(non_snake_case)]
pub fn BlockedUsers(cx: Scope) -> Element {
    let state = use_shared_state::<State>(cx).unwrap();
    let block_list = state.read().friends.blocked.clone();

    cx.render(rsx! (
        div {
            class: "friends-list",
            Label {
                text: get_local_text("friends.blocked"),
            },
            block_list.into_iter().map(|blocked_user| {
                let did = blocked_user.did_key();
                let did_suffix: String = did.to_string().chars().rev().take(6).collect();
                let unblock_user = blocked_user.clone();
                let unblock_user_clone = unblock_user.clone();
                let platform = match blocked_user.platform() {
                    warp::multipass::identity::Platform::Desktop => Platform::Desktop,
                    warp::multipass::identity::Platform::Mobile => Platform::Mobile,
                    _ => Platform::Headless //TODO: Unknown
                };
                let status = match blocked_user.identity_status() {
                    warp::multipass::identity::IdentityStatus::Online => Status::Online,
                    warp::multipass::identity::IdentityStatus::Away => Status::Idle,
                    warp::multipass::identity::IdentityStatus::Busy => Status::DoNotDisturb,
                    warp::multipass::identity::IdentityStatus::Offline => Status::Offline,
                };
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
                            relationship: Relationship::default(),
                            user_image: cx.render(rsx! (
                                UserImage {
                                    platform: platform,
                                    status: status,
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
