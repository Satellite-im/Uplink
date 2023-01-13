use dioxus::prelude::*;

use kit::{layout::{topbar::Topbar, chatbar::{Chatbar, Reply}}, components::{user_image::UserImage, indicator::{Status, Platform}, context_menu::{ContextMenu, ContextItem}, message_group::{MessageGroup, MessageGroupSkeletal}, message::{Message, Order}, user_image_group::UserImageGroup}, elements::{button::Button, tooltip::{Tooltip, ArrowPosition}, Appearance}, icons::Icon};

use dioxus_desktop::use_window;
use shared::language::get_local_text;


use crate::{state::{State, Action, Chat, Identity, self}, components::{chat::sidebar::build_participants, media::player::MediaPlayer}, utils::{format_timestamp::format_timestamp_timeago, convert_status}};


use super::sidebar::build_participants_names;

struct ComposeData {
    active_chat: Chat,
    message_groups: Vec<state::MessageGroup>,
    other_participants: Vec<Identity>,
    active_participant: Identity,
    subtext: String,
    is_favorite: bool,
    reply_message: Option<String>,
    first_image: String,
    other_participants_names: String,
    active_media: bool,
    platform: Platform
}

#[allow(non_snake_case)]
pub fn Compose(cx: Scope) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let s = state.read();
    let active_chat = s.get_active_chat().expect("compose page called without an active chat");
    let message_groups = s.get_sort_messages(&active_chat);
    let other_participants = s.get_without_me(active_chat.participants.clone());
    let active_participant = other_participants.first().cloned().expect("chat should have at least 2 participants");
    let subtext = active_participant.status_message().unwrap_or_default();
    let is_favorite = s.is_favorite(&active_chat);
    let first_image = active_participant.graphics().profile_picture();
    let other_participants_names = build_participants_names(&other_participants);
    let active_media = Some(active_chat.id) == s.chats.active_media;

    // TODO: Pending new message divider implementation
    // let _new_message_text = LOCALES
    //     .lookup(&*APP_LANG.read(), "messages.new")
    //     .unwrap_or_default();

    let platform = match active_participant.platform() {
        warp::multipass::identity::Platform::Desktop => Platform::Desktop,
        warp::multipass::identity::Platform::Mobile => Platform::Mobile,
        _ => Platform::Headless //TODO: Unknown
    };


    let desktop = use_window(cx);
    let loading = use_state(cx, || false);

    cx.render(rsx!(
        div {
            id: "compose",
            Topbar {
                with_back_button: state.read().ui.is_minimal_view() || state.read().ui.sidebar_hidden,
                with_currently_back: state.read().ui.sidebar_hidden,
                onback: move |_| {
                    let current = state.read().ui.sidebar_hidden;
                    state.write().mutate(Action::SidebarHidden(!current));
                },
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
                                state.write_silent().mutate(Action::ClearPopout(desktop.clone()));
                                state.write_silent().mutate(Action::DisableMedia);
                                state.write().mutate(Action::SetActiveMedia(active_chat.id));
                            }
                        },
                        (!state.read().ui.is_minimal_view()).then(|| rsx!(
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
                        ))
                    )
                ),
                cx.render(
                    rsx! (
                        if other_participants.len() < 2 {rsx! (
                            UserImage {
                                loading: **loading,
                                platform: platform,
                                status: convert_status(&active_participant.identity_status()),
                                image: first_image
                            }
                        )} else {rsx! (
                            UserImageGroup {
                                loading: **loading,
                                participants: build_participants(&other_participants)
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
                                        "{other_participants_names}"
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
                                let status = convert_status(&sender.identity_status());

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
                                                                state.write().mutate(Action::StartReplying(active_chat, reply_message.clone()));
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
                    active_chat.replying_to.map(|msg| rsx!(
                        Reply {
                            label: get_local_text("messages.replying"),
                            remote: {
                                let our_did = state.read().account.identity.did_key();
                                let their_did = msg.sender();
                                our_did != their_did
                            },
                            onclose: move |_| {
                                state.write().mutate(Action::CancelReply(active_chat))
                            },
                            message: msg.value().join("\n"),
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
