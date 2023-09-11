mod chatbar;
mod context_file_location;
mod messages;
mod quick_profile;

use std::rc::Rc;

use dioxus::prelude::*;

use futures::{channel::oneshot, StreamExt};
use kit::{
    components::{
        indicator::Platform, message_group::MessageGroupSkeletal, user_image::UserImage,
        user_image_group::UserImageGroup,
    },
    elements::{
        button::Button,
        input::{Input, Options},
        tooltip::{ArrowPosition, Tooltip},
        Appearance,
    },
    layout::{modal::Modal, topbar::Topbar},
};

use crate::components::{
    chat::create_group::get_input_options, chat::pinned_messages::PinnedMessages,
    media::calling::CallControl,
};

use common::{
    icons::outline::Shape as Icon,
    state::call,
    warp_runner::{BlinkCmd, RayGunCmd, WarpCmd},
};
use common::{
    state::{ui, Action, Chat, Identity, State},
    WARP_CMD_CH,
};

use common::language::get_local_text;

use uuid::Uuid;
use warp::{
    blink::{self},
    crypto::DID,
    logging::tracing::log,
    raygun::ConversationType,
};

use crate::{
    components::chat::{edit_group::EditGroup, group_users::GroupUsers},
    utils::build_participants,
};

pub struct ComposeData {
    active_chat: Chat,
    my_id: Identity,
    other_participants: Vec<Identity>,
    active_participant: Identity,
    subtext: String,
    is_favorite: bool,
    first_image: String,
    other_participants_names: String,
    platform: Platform,
}

impl PartialEq for ComposeData {
    fn eq(&self, _other: &Self) -> bool {
        false
    }
}

#[derive(PartialEq, Props)]
pub struct ComposeProps {
    #[props(!optional)]
    data: Option<Rc<ComposeData>>,
    show_edit_group: UseState<Option<Uuid>>,
    show_group_users: UseState<Option<Uuid>>,
    ignore_focus: bool,
    is_owner: bool,
    is_edit_group: bool,
}

#[allow(non_snake_case)]
pub fn Compose(cx: Scope) -> Element {
    log::trace!("rendering compose");
    let state = use_shared_state::<State>(cx)?;
    let data = get_compose_data(cx);
    let data2 = data.clone();
    let chat_id = data2
        .as_ref()
        .map(|data| data.active_chat.id)
        .unwrap_or(Uuid::nil());

    state.write_silent().ui.current_layout = ui::Layout::Compose;
    if state.read().chats().active_chat_has_unreads() {
        state.write().mutate(Action::ClearActiveUnreads);
    }

    let show_edit_group: &UseState<Option<Uuid>> = use_state(cx, || None);
    let show_group_users: &UseState<Option<Uuid>> = use_state(cx, || None);

    let should_ignore_focus = state.read().ui.ignore_focus;

    let active_chat = data.as_ref().map(|x| &x.active_chat);
    let creator = if let Some(chat) = active_chat.as_ref() {
        chat.creator.clone()
    } else {
        None
    };

    let user_did: DID = state.read().did_key();
    let is_owner = if let Some(creator_did) = creator {
        creator_did == user_did
    } else {
        false
    };

    let is_edit_group = show_edit_group.map_or(false, |group_chat_id| (group_chat_id == chat_id));

    cx.render(rsx!(
        div {
            id: "compose",
            Topbar {
                with_back_button: state.read().ui.is_minimal_view() && state.read().ui.sidebar_hidden,
                onback: move |_| {
                    let current = state.read().ui.sidebar_hidden;
                    state.write().mutate(Action::SidebarHidden(!current));
                },
                controls: cx.render(rsx!(get_controls{
                    data: data2.clone(),
                    show_edit_group: show_edit_group.clone(),
                    show_group_users: show_group_users.clone(),
                    ignore_focus: should_ignore_focus,
                    is_owner: is_owner,
                    is_edit_group: is_edit_group,
                })),
                get_topbar_children {
                    data: data.clone(),
                    show_edit_group: show_edit_group.clone(),
                    show_group_users: show_group_users.clone(),
                    ignore_focus: should_ignore_focus,
                    is_owner: is_owner,
                    is_edit_group: is_edit_group,
                }
            },
            // may need this later when video calling is possible.
            // data.as_ref().and_then(|data| data.active_media.then(|| rsx!(
            //     MediaPlayer {
            //         settings_text: get_local_text("settings.settings"),
            //         enable_camera_text: get_local_text("media-player.enable-camera"),
            //         fullscreen_text: get_local_text("media-player.fullscreen"),
            //         popout_player_text: get_local_text("media-player.popout-player"),
            //         screenshare_text: get_local_text("media-player.screenshare"),
            //         end_text: get_local_text("uplink.end"),
            //     },
            // ))),
        show_edit_group
            .map_or(false, |group_chat_id| (group_chat_id == chat_id)).then(|| rsx!(
                Modal {
                    open: show_edit_group.is_some(),
                    transparent: true,
                    with_title: get_local_text("friends.edit-group"),
                    onclose: move |_| {
                        show_edit_group.set(None);
                    },
                    EditGroup {}
                }
            )),
        show_group_users
            .map_or(false, |group_chat_id| (group_chat_id == chat_id)).then(|| rsx!(
                Modal {
                    open: show_group_users.is_some(),
                    transparent: true,
                    with_title: get_local_text("friends.view-group"),
                    onclose: move |_| {
                        show_group_users.set(None);
                    },
                    GroupUsers {
                        active_chat: state.read().get_active_chat(),
                    }
                }
        )),
        CallControl {
            in_chat: true
        },
        match data.as_ref() {
            None => rsx!(
                div {
                    id: "messages",
                    MessageGroupSkeletal {},
                    MessageGroupSkeletal { alt: true },
                    MessageGroupSkeletal {},
                }
            ),
            Some(_data) =>  rsx!(messages::get_messages{data: _data.clone()}),
        },
        chatbar::get_chatbar {
            data: data.clone(),
            show_edit_group: show_edit_group.clone(),
            show_group_users: show_group_users.clone(),
            ignore_focus: should_ignore_focus,
            is_owner: is_owner,
            is_edit_group: is_edit_group,
        }
    }
    ))
}

fn get_compose_data(cx: Scope) -> Option<Rc<ComposeData>> {
    let state = use_shared_state::<State>(cx)?;
    let s = state.read();
    // the Compose page shouldn't be called before chats is initialized. but check here anyway.
    if !s.initialized {
        return None;
    }

    let active_chat = match s.get_active_chat() {
        Some(c) => c,
        None => return None,
    };
    let participants = s.chat_participants(&active_chat);
    // warning: if a friend changes their username, if state.friends is updated, the old username would still be in state.chats
    // this would be "fixed" the next time uplink starts up
    let other_participants: Vec<Identity> = s.remove_self(&participants);
    let active_participant = other_participants
        .first()
        .cloned()
        .unwrap_or(s.get_own_identity());

    let subtext = match active_chat.conversation_type {
        ConversationType::Direct => active_participant.status_message().unwrap_or_default(),
        _ => String::new(),
    };
    let is_favorite = s.is_favorite(&active_chat);

    let first_image = active_participant.profile_picture();
    let other_participants_names = State::join_usernames(&other_participants);

    // TODO: Pending new message divider implementation
    // let _new_message_text = LOCALES
    //     .lookup(&*APP_LANG.read(), "messages.new")
    //     .unwrap_or_default();

    let platform = active_participant.platform().into();

    let data = Rc::new(ComposeData {
        active_chat,
        other_participants,
        my_id: s.get_own_identity(),
        active_participant,
        subtext,
        is_favorite,
        first_image,
        other_participants_names,
        platform,
    });

    Some(data)
}

enum ControlsCmd {
    VoiceCall {
        participants: Vec<DID>,
        conversation_id: Uuid,
    },
}

enum EditGroupCmd {
    UpdateGroupName((Uuid, String)),
}

fn get_controls(cx: Scope<ComposeProps>) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let data = &cx.props.data;
    let active_chat = data.as_ref().map(|x| &x.active_chat);
    let favorite = data
        .as_ref()
        .map(|d: &Rc<ComposeData>| d.is_favorite)
        .unwrap_or_default();
    let conversation_type = if let Some(chat) = active_chat.as_ref() {
        chat.conversation_type
    } else {
        ConversationType::Direct
    };
    let edit_group_activated = cx
        .props
        .show_edit_group
        .get()
        .map(|group_chat_id| active_chat.map_or(false, |chat| group_chat_id == chat.id))
        .unwrap_or(false);
    let show_group_list = cx
        .props
        .show_group_users
        .get()
        .map(|group_chat_id| active_chat.map_or(false, |chat| group_chat_id == chat.id))
        .unwrap_or(false);

    let call_pending = use_state(cx, || false);
    let active_call = state.read().ui.call_info.active_call();
    let call_in_progress = active_call.is_some(); // active_chat.map(|chat| chat.id) == active_call.map(|call| call.conversation_id);

    let show_pinned = use_state(cx, || false);

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<ControlsCmd>| {
        to_owned![call_pending, state];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(cmd) = rx.next().await {
                match cmd {
                    ControlsCmd::VoiceCall {
                        participants,
                        conversation_id,
                    } => {
                        let (tx, rx) = oneshot::channel();
                        if let Err(e) = warp_cmd_tx.send(WarpCmd::Blink(BlinkCmd::OfferCall {
                            conversation_id,
                            participants: participants.clone(),
                            rsp: tx,
                            // todo: make this configurable
                            webrtc_codec: blink::AudioCodec {
                                mime: blink::MimeType::OPUS,
                                sample_rate: blink::AudioSampleRate::High,
                                channels: 1,
                            },
                        })) {
                            log::error!("failed to send command to warp_runner: {e}");
                            call_pending.set(false);
                            continue;
                        }

                        let res = rx.await.expect("warp runner failed");
                        match res {
                            Ok(call_id) => {
                                state.write().mutate(Action::OfferCall(call::Call::new(
                                    call_id,
                                    conversation_id,
                                    participants,
                                )));
                            }
                            Err(e) => {
                                log::error!("BlinkCmd::OfferCall failed: {e}");
                            }
                        }
                        call_pending.set(false);
                    }
                }
            }
        }
    });

    cx.render(rsx!(
        if cx.props.is_owner && conversation_type == ConversationType::Group {
            rsx!(Button {
                icon: Icon::PencilSquare,
                aria_label: "edit-group".into(),
                appearance: if edit_group_activated {
                    Appearance::Primary
                } else {
                    Appearance::Secondary
                },
                tooltip: cx.render(rsx!(Tooltip {
                    arrow_position: ArrowPosition::Top,
                    text: get_local_text("friends.edit-group")
                })),
                onpress: move |_| {
                    if edit_group_activated {
                        cx.props.show_edit_group.set(None);
                    } else if let Some(chat) = active_chat.as_ref() {
                        cx.props.show_edit_group.set(Some(chat.id));
                        cx.props.show_group_users.set(None);
                    }
                }
            })
        }
        if !cx.props.is_owner && conversation_type == ConversationType::Group {
            rsx!(
                Button {
                    icon: Icon::ListBullet,
                    aria_label: "edit-group".into(),
                    appearance: if show_group_list {
                        Appearance::Primary
                    } else {
                        Appearance::Secondary
                    },
                    tooltip: cx.render(rsx!(Tooltip {
                        arrow_position: ArrowPosition::Top,
                        text: get_local_text("friends.view-group")
                    })),
                    onpress: move |_| {
                            if show_group_list {
                                cx.props.show_group_users.set(None);
                            } else if let Some(chat) = active_chat.as_ref() {
                                cx.props.show_group_users.set(Some(chat.id));
                                cx.props.show_edit_group.set(None);

                            }

                    }
                }
            )
        }
        Button {
            icon: if favorite {
                Icon::HeartSlash
            } else {
                Icon::Heart
            },
            disabled: data.is_none(),
            aria_label: get_local_text(if favorite {
                "favorites.remove"
            } else {
                "favorites.favorites"
            }),
            appearance: if favorite {
                Appearance::Primary
            } else {
                Appearance::Secondary
            },
            tooltip: cx.render(rsx!(Tooltip {
                arrow_position: ArrowPosition::Top,
                text: if favorite {
                    get_local_text("favorites.remove")
                } else {
                    get_local_text("favorites.add")
                }
            })),
            onpress: move |_| {
                if let Some(chat) = active_chat.as_ref() {
                    state.write().mutate(Action::ToggleFavorite(&chat.id));
                }
            }
        },
        show_pinned.then(|| rsx!(
            Modal {
                open: true,
                transparent: true,
                with_title: get_local_text("messages.pin-view"),
                onclose: move |_| {
                    show_pinned.set(false);
                },
                if let Some(chat) = active_chat {
                    rsx!(PinnedMessages{ active_chat: chat.clone(), onclose: move |_| {
                        show_pinned.set(false);
                    } })
                }
            }
        )),
        Button {
            icon: Icon::Pin,
            aria_label: "pin-label".into(),
            appearance: if *show_pinned.clone() { Appearance::Primary } else { Appearance::Secondary },
            tooltip: cx.render(rsx!(Tooltip {
                arrow_position: ArrowPosition::Top,
                text: get_local_text("messages.pin-view"),
            })),
            onpress: move |_| {
                show_pinned.set(true);
            }
        }
        Button {
            icon: Icon::PhoneArrowUpRight,
            disabled: !state.read().configuration.developer.experimental_features || *call_pending.current() || call_in_progress,
            aria_label: "Call".into(),
            appearance: Appearance::Secondary,
            tooltip: cx.render(rsx!(Tooltip {
                arrow_position: ArrowPosition::Top,
                text: if !state.read().configuration.developer.experimental_features { get_local_text("uplink.coming-soon") } else { get_local_text("uplink.call") }
            })),
            onpress: move |_| {
                if let Some(chat) = active_chat.as_ref() {
                    ch.send(ControlsCmd::VoiceCall{
                        participants: chat.participants.iter().cloned().collect(),
                        conversation_id: chat.id
                    });
                    call_pending.set(true);
                }
            }
        },
        Button {
            icon: Icon::VideoCamera,
            disabled: true,
            aria_label: "Videocall".into(),
            appearance: Appearance::Secondary,
            tooltip: cx.render(rsx!(Tooltip {
                arrow_position: ArrowPosition::TopRight,
                text: get_local_text("uplink.coming-soon"),
            })),
        },
    ))
}

fn get_topbar_children(cx: Scope<ComposeProps>) -> Element {
    let data = cx.props.data.clone();
    let data = match data {
        Some(d) => d,
        None => {
            return cx.render(rsx!(
                UserImageGroup {
                    loading: true,
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
    let members_count = format!(
        "{} ({})",
        get_local_text("uplink.members"),
        all_participants.len()
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
