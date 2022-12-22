
use dioxus::{prelude::*, desktop::use_window};
use kit::{layout::{topbar::Topbar, chatbar::{Chatbar, Reply}}, components::{user_image::UserImage, indicator::{Status, Platform}, context_menu::{ContextMenu, ContextItem}, message_group::MessageGroup, message::{Message, Order}, user_image_group::UserImageGroup}, elements::{button::Button, tooltip::{Tooltip, ArrowPosition}, Appearance}, icons::Icon};
use warp::multipass::identity::Identity;

use crate::{state::{State, Action}, components::{chat::sidebar::build_participants, media::player::MediaPlayer}, utils::{language::get_local_text, format_timestamp::format_timestamp_timeago}};

use super::sidebar::build_participants_names;

#[allow(non_snake_case)]
pub fn Compose(cx: Scope) -> Element {
    let state: UseSharedState<State> = use_context::<State>(&cx).unwrap();
    let active_chat = state.read().get_active_chat().unwrap_or_default();
    let message_groups = state.read().get_sort_messages(&active_chat);

    let without_me = state.read().get_without_me(active_chat.participants.clone());
    let active_participant = without_me.first();

    let active_participant = match active_participant {
        Some(u) => u.clone(),
        None => Identity::default(),
    };

    let subtext = active_participant.status_message().unwrap_or_default();

    let is_favorite = state.read().is_favorite(&active_chat);

    let reply_message = match state.read().get_active_chat().unwrap_or_default().replying_to {
        Some(m) => m.value().join("\n").to_string(),
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

    let desktop = use_window(&cx);

    cx.render(rsx!(
        div {
            id: "compose",
            div {
                onmousedown: move |_| { desktop.drag(); },
                Topbar {
                    with_back_button: false,
                    controls: cx.render(
                        rsx! (
                            Button {
                                icon: Icon::Heart,
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
                                appearance: Appearance::Secondary,
                                tooltip: cx.render(rsx!(
                                    Tooltip { 
                                        arrow_position: ArrowPosition::Top, 
                                        text: get_local_text("uplink.call"),
                                    }
                                )),
                                onpress: move |_| {
                                    let _ = state.write().mutate(Action::ToggleMedia(active_media_chat.clone()));
                                }
                            },
                            Button {
                                icon: Icon::VideoCamera,
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
                                    platform: Platform::Mobile,
                                    status: Status::Online,
                                    image: first_image
                                }
                            )} else {rsx! (
                                UserImageGroup {
                                    participants: build_participants(&without_me)
                                }
                            )}
                            div {
                                class: "user-info",
                                p {
                                    class: "username",
                                    "{participants_name}"
                                },
                                p {
                                    class: "status",
                                    "{subtext}"
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
            div {
                id: "messages",
                div {
                    message_groups.iter().map(|group| {
                        let messages = &group.messages;
                        let last_message = messages.last().unwrap().message.clone();
                        let sender = state.read().get_friend_identity(&group.sender);    
                        let active_language = state.read().settings.language.clone();

                        rsx!(
                            MessageGroup {
                                user_image: cx.render(rsx!(
                                    UserImage {
                                        platform: Platform::Mobile,
                                        status: Status::Online
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
            Chatbar {
                placeholder: get_local_text("messages.say-something-placeholder"),
                controls: cx.render(rsx!(
                    Button {
                        icon: Icon::ChevronDoubleRight,
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
                                let their_did = state.read().get_active_chat().unwrap_or_default().replying_to.clone().unwrap_or_default().sender();
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
