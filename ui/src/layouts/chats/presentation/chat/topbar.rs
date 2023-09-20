use dioxus::prelude::*;
use futures::{channel::oneshot, StreamExt};
use kit::{
    components::{user_image::UserImage, user_image_group::UserImageGroup},
    elements::input::{Input, Options},
};

use common::WARP_CMD_CH;
use common::{
    language::get_local_text_with_args,
    warp_runner::{RayGunCmd, WarpCmd},
};

use common::language::get_local_text;

use uuid::Uuid;
use warp::{logging::tracing::log, raygun::ConversationType};

use crate::{
    layouts::chats::data::{get_input_options, ChatProps},
    utils::build_participants,
};

enum EditGroupCmd {
    UpdateGroupName((Uuid, String)),
}

pub fn get_topbar_children(cx: Scope<ChatProps>) -> Element {
    let data = cx.props.data.clone();
    let data = match data {
        Some(d) => d,
        None => {
            return cx.render(rsx!(
                UserImageGroup {
                    loading: true,
                    aria_label: "user-image-group".into(),
                    participants: vec![]
                },
                div {
                    class: "user-info",
                    aria_label: "user-info",
                    div {
                        class: "skeletal-bars",
                        div {
                            class: "skeletal skeletal-bar",
                        },
                        div {
                            class: "skeletal skeletal-bar",
                        },
                    }
                }
            ))
        }
    };

    let conversation_title = match data.active_chat.conversation_name.as_ref() {
        Some(n) => n.clone(),
        None => data.other_participants_names.clone(),
    };
    let subtext = data.subtext.clone();

    let direct_message = data.active_chat.conversation_type == ConversationType::Direct;

    let active_participant = data.my_id.clone();
    let mut all_participants = data.other_participants.clone();
    all_participants.push(active_participant);
    let members_count = get_local_text_with_args(
        "uplink.members-count",
        vec![("num", all_participants.len().into())],
    );

    let conv_id = data.active_chat.id;

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<EditGroupCmd>| async move {
        let warp_cmd_tx = WARP_CMD_CH.tx.clone();
        while let Some(cmd) = rx.next().await {
            match cmd {
                EditGroupCmd::UpdateGroupName((conv_id, new_conversation_name)) => {
                    let (tx, rx) = oneshot::channel();
                    if let Err(e) =
                        warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::UpdateConversationName {
                            conv_id,
                            new_conversation_name,
                            rsp: tx,
                        }))
                    {
                        log::error!("failed to send warp command: {}", e);
                        continue;
                    }
                    let res = rx.await.expect("command canceled");
                    if let Err(e) = res {
                        log::error!("failed to update group conversation name: {}", e);
                    }
                }
            }
        }
    });

    cx.render(rsx!(
        if direct_message {rsx! (
            UserImage {
                loading: false,
                platform: data.platform,
                status: data.active_participant.identity_status().into(),
                image: data.first_image.clone(),
            }
        )} else {rsx! (
            UserImageGroup {
                loading: false,
                aria_label: "user-image-group".into(),
                participants: build_participants(&all_participants),
            }
        )}
        div {
            class: "user-info",
            aria_label: "user-info",
            if cx.props.is_edit_group {rsx! (
                div {
                    id: "edit-group-name",
                    class: "edit-group-name",
                    Input {
                            placeholder:  get_local_text("messages.group-name"),
                            default_text: conversation_title.clone(),
                            aria_label: "groupname-input".into(),
                            options: Options {
                                with_clear_btn: true,
                                ..get_input_options()
                            },
                            onreturn: move |(v, is_valid, _): (String, bool, _)| {
                                if !is_valid {
                                    return;
                                }
                                if v != conversation_title.clone() {
                                    ch.send(EditGroupCmd::UpdateGroupName((conv_id, v)));
                                }
                            },
                        },
                })
            } else {rsx!(
                p {
                    aria_label: "user-info-username",
                    class: "username",
                    "{conversation_title}"
                },
                p {
                    aria_label: "user-info-status",
                    class: "status",
                    if direct_message {
                        rsx! (span {
                            "{subtext}"
                        })
                    } else {
                        rsx! (
                            span {"{members_count}"}
                        )
                    }
                }
            )}
        }
    ))
}
