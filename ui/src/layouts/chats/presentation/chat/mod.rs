mod controls;
pub mod coroutines;
mod edit_group;
mod group_users;
mod pinned_messages;
mod topbar;

use dioxus::prelude::*;

use kit::{
    components::message_group::MessageGroupSkeletal,
    layout::{modal::Modal, topbar::Topbar},
};

use crate::{
    components::media::calling::CallControl,
    layouts::chats::{
        data::{ChatData, ScrollBtn},
        presentation::{
            chat::{edit_group::EditGroup, group_users::GroupUsers},
            chatbar::get_chatbar,
            messages::get_messages,
        },
    },
};

use common::state::{ui, Action, State};

use common::language::get_local_text;

use uuid::Uuid;
use warp::{crypto::DID, logging::tracing::log};

#[allow(non_snake_case)]
pub fn Compose(cx: Scope) -> Element {
    log::trace!("rendering compose");
    use_shared_state_provider(cx, ChatData::default);
    use_shared_state_provider(cx, ScrollBtn::new);
    let state = use_shared_state::<State>(cx)?;
    let chat_data = use_shared_state::<ChatData>(cx)?;

    let init = coroutines::init_chat_data(cx, state, chat_data);
    coroutines::handle_warp_events(cx, state, chat_data);

    // todo: get rid fo this data variable
    let data = chat_data.read();
    let chat_id = data.active_chat.id();

    state.write_silent().ui.current_layout = ui::Layout::Compose;

    let show_edit_group: &UseState<Option<Uuid>> = use_state(cx, || None);
    let show_group_users: &UseState<Option<Uuid>> = use_state(cx, || None);

    let should_ignore_focus = state.read().ui.ignore_focus;
    let creator = data.active_chat.creator().clone();

    let user_did: DID = state.read().did_key();
    let is_owner = creator.map(|id| id == user_did).unwrap_or_default();

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
                controls: cx.render(rsx!(controls::get_controls{
                    show_edit_group: show_edit_group.clone(),
                    show_group_users: show_group_users.clone(),
                    ignore_focus: should_ignore_focus,
                    is_owner: is_owner,
                    is_edit_group: is_edit_group,
                })),
                topbar::get_topbar_children {
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
        if init.value().is_none() {
           rsx!(
                div {
                    id: "messages",
                    MessageGroupSkeletal {},
                    MessageGroupSkeletal { alt: true },
                    MessageGroupSkeletal {},
                }
            )
        } else {
            rsx!(get_messages{})
        },
        get_chatbar {
            show_edit_group: show_edit_group.clone(),
            show_group_users: show_group_users.clone(),
            ignore_focus: should_ignore_focus,
            is_owner: is_owner,
            is_edit_group: is_edit_group,
        }
    }
    ))
}
