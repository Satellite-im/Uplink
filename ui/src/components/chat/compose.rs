use dioxus::prelude::*;

use kit::{layout::{topbar::Topbar, chatbar::{Chatbar, Reply}}, components::{user_image::UserImage, indicator::{Status, Platform}, context_menu::{ContextMenu, ContextItem}, message_group::{MessageGroup, MessageGroupSkeletal}, message::{Message, Order}, user_image_group::UserImageGroup}, elements::{button::Button, tooltip::{Tooltip, ArrowPosition}, Appearance}, icons::Icon};

use dioxus_desktop::use_window;


use crate::{state::{State, Action}, components::{chat::sidebar::build_participants, media::player::MediaPlayer}, utils::{language::get_local_text, format_timestamp::format_timestamp_timeago}};


use super::sidebar::build_participants_names;

#[allow(non_snake_case)]
pub fn Compose(cx: Scope) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let active_chat = state.read().get_active_chat().unwrap_or_default();
    let message_groups = state.read().get_sort_messages(&active_chat);

    let without_me = state.read().get_without_me(active_chat.participants.clone());
    let active_participant = without_me.first().cloned();

    let active_participant = active_participant.unwrap_or_default();

    let subtext = active_participant.status_message().unwrap_or_default();

    let is_favorite = state.read().is_favorite(&active_chat);

    let reply_message = match state.read().get_active_chat().unwrap_or_default().replying_to {
        Some(m) => m.value().join("\n"),
        None => "".into(),
    };

    let first_image = active_participant.graphics().profile_picture();
    let participants_name = build_participants_names(&without_me);

    let active_media = active_chat.active_media;
    let active_media_chat = active_chat.clone();
 
    // TODO: Pending new message divider implementation
    // let _new_message_text = LOCALES
    //     .lookup(&*APP_LANG.read(), "messages.new")
    //     .unwrap_or_default();

    let platform = match active_participant.platform() {
        warp::multipass::identity::Platform::Desktop => Platform::Desktop,
        warp::multipass::identity::Platform::Mobile => Platform::Mobile,
        _ => Platform::Headless //TODO: Unknown
    };
    let status = match active_participant.identity_status() {
        warp::multipass::identity::IdentityStatus::Online => Status::Online,
        warp::multipass::identity::IdentityStatus::Away => Status::Idle,
        warp::multipass::identity::IdentityStatus::Busy => Status::DoNotDisturb,
        warp::multipass::identity::IdentityStatus::Offline => Status::Offline,
    };
    let desktop = use_window(&cx);

    let loading = use_state(cx, || false);

    cx.render(rsx!(
        div {
            id: "compose",
            div {
                onmousedown: move |_| { desktop.drag(); },
                Topbar {
                    with_back_button: true,
                    controls: cx.render(
                        rsx! (
                            Button {
                                icon: Icon::Heart,
                                // disabled: **loading,
                                appearance: if is_favorite { Appearance::Primary } else { Appearance::Secondary },
                                tooltip: cx.render(rsx!(
                                    Tooltip { 
                                        arrow_position: ArrowPosition::Top, 
                                        text: get_local_text("favorites.add"),
                                    }
                                )),
                                onpress: move |_| {
                                    state.write().mutate(Action::ToggleFavorite(active_chat.clone()));
                                }
                            },
                            Button {
                                icon: Icon::PhoneArrowUpRight,
                                // disabled: **loading,
                                appearance: Appearance::Secondary,
                                tooltip: cx.render(rsx!(
                                    Tooltip { 
                                        arrow_position: ArrowPosition::Top, 
                                        text: get_local_text("uplink.call"),
                                    }
                                )),
                                onpress: move |_| {
                                    state.write().mutate(Action::ToggleMedia(active_media_chat.clone()));
                                }
                            },
                            Button {
                                icon: Icon::VideoCamera,
                                // disabled: **loading,
                                appearance: Appearance::Secondary,
                                tooltip: cx.render(rsx!(
                                    Tooltip { 
                                        arrow_position: ArrowPosition::Top, 
                                        text: get_local_text("uplink.video-call"),
                                    }
                                )),
                            },
                        )
                    ),
                    cx.render(
                        rsx! (
                            if without_me.len() < 2 {rsx! (
                                UserImage {
                                    loading: **loading,
                                    platform: platform,
                                    status: status,
                                    image: first_image
                                }
                            )} else {rsx! (
                                UserImageGroup {
                                    loading: **loading,
                                    participants: build_participants(&without_me)
                                }
                            )}
                            div {
                                class: "user-info",
                                if **loading {
                                    rsx!(
                                        div {
                                            class: "skeletal-bars",
                                            div {
                                                class: "skeletal skeletal-bar",
                                            },
                                            div {
                                                class: "skeletal skeletal-bar",
                                            },
                                        }
                                    )
                                } else {
                                    rsx! (
                                        p {
                                            class: "username",
                                            "{participants_name}"
                                        },
                                        p {
                                            class: "status",
                                            "{subtext}"
                                        }
                                    )
                                }
                            }
                        )
                    ),
                },
            },
            active_media.then(|| rsx!(
                MediaPlayer {
                    settings_text: get_local_text("settings.settings"), 
                    enable_camera_text: get_local_text("media-player.enable-camera"),
                    fullscreen_text: get_local_text("media-player.fullscreen"),
                    popout_player_text: get_local_text("media-player.popout-player"),
                    screenshare_text: get_local_text("media-player.screenshare"),
                    end_text: get_local_text("uplink.end"),
                },
            )),
            if **loading {
                rsx!(
                    div {
                        id: "messages",
                        MessageGroupSkeletal {},
                        MessageGroupSkeletal { alt: true }
                    }
                )
            } else {
                rsx! (
                    div {
                        id: "messages",
                        div {
                            message_groups.iter().map(|group| {
                                let messages = &group.messages;
                                let last_message = messages.last().unwrap().message.clone();
                                let sender = state.read().get_friend_identity(&group.sender);    
                                let active_language = state.read().settings.language.clone();
                                let platform = match sender.platform() {
                                    warp::multipass::identity::Platform::Desktop => Platform::Desktop,
                                    warp::multipass::identity::Platform::Mobile => Platform::Mobile,
                                    _ => Platform::Headless //TODO: Unknown
                                };
                                let status = match sender.identity_status() {
                                    warp::multipass::identity::IdentityStatus::Online => Status::Online,
                                    warp::multipass::identity::IdentityStatus::Away => Status::Idle,
                                    warp::multipass::identity::IdentityStatus::Busy => Status::DoNotDisturb,
                                    warp::multipass::identity::IdentityStatus::Offline => Status::Offline,
                                };

                                rsx!(
                                    MessageGroup {
                                        user_image: cx.render(rsx!(
                                            UserImage {
                                                platform: platform,
                                                status: status
                                            }
                                        )),
                                        timestamp: format_timestamp_timeago(last_message.date(), active_language),
                                        with_sender: if sender.username().is_empty() { get_local_text("messages.you") } else { sender.username()},
                                        remote: group.remote,
                                        messages.iter().map(|grouped_message| {
                                            let message = grouped_message.message.clone();
                                            let reply_message = grouped_message.message.clone();
                                        
                                            rsx! (
                                                ContextMenu {
                                                    id: format!("message-{}", message.id()),
                                                    items: cx.render(rsx!(
                                                        ContextItem {
                                                            icon: Icon::ArrowLongLeft,
                                                            text: get_local_text("messages.reply"),
                                                            onpress: move |_| {
                                                                let chat = state.read().get_active_chat().unwrap_or_default();
                                                                state.write().mutate(Action::StartReplying(chat, reply_message.clone()));
                                                            }
                                                        },
                                                        ContextItem {
                                                            icon: Icon::FaceSmile,
                                                            text: get_local_text("messages.react"),
                                                            //TODO: Wire to state
                                                        },
                                                    )),
                                                    Message {
                                                        remote: group.remote,
                                                        with_text: message.value().join("\n"),
                                                        order: if grouped_message.is_first { Order::First } else if grouped_message.is_last { Order::Last } else { Order::Middle },
                                                    }
                                                }
                                            )
                                        })
                                    }
                                )
                            })
                        }
                    },
                )
            },
            Chatbar {
                loading: **loading,
                placeholder: get_local_text("messages.say-something-placeholder"),
                controls: cx.render(rsx!(
                    Button {
                        icon: Icon::ChevronDoubleRight,
                        // disabled: **loading,
                        appearance: Appearance::Secondary,
                        tooltip: cx.render(rsx!(
                            Tooltip { 
                                arrow_position: ArrowPosition::Bottom, 
                                text: get_local_text("uplink.send"),
                            }
                        )),
                    },
                )),
                with_replying_to: cx.render(rsx!(
                    state.read().get_active_chat().unwrap_or_default().replying_to.is_some().then(|| rsx!(
                        Reply {
                            label: get_local_text("messages.replying"),
                            remote: {
                                let our_did = state.read().account.identity.did_key();
                                let their_did = state.read().get_active_chat().unwrap_or_default().replying_to.unwrap_or_default().sender();
                                our_did != their_did
                            },
                            onclose: move |_| {
                                let new_chat = &state.read().get_active_chat().unwrap_or_default();
                                state.write().mutate(Action::CancelReply(new_chat.clone()))
                            },
                            message: reply_message,
                            UserImage {
                                platform: Platform::Mobile,
                                status: Status::Online
                            },
                        }
                    ))
                )),
                with_file_upload: cx.render(rsx!(
                    Button {
                        icon: Icon::Plus,
                        // disabled: **loading,
                        appearance: Appearance::Primary,
                        tooltip: cx.render(rsx!(
                            Tooltip { 
                                arrow_position: ArrowPosition::Bottom, 
                                text: get_local_text("files.upload"),
                            }
                        ))
                    }
                ))
            }
        }  
    ))
}
