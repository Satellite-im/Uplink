mod controls;
mod edit_group;
mod futures;
mod group_users;
mod pinned_messages;
mod topbar;

use std::rc::Rc;

use dioxus::prelude::*;

use futures::channel::oneshot;
use kit::{
    components::message_group::MessageGroupSkeletal,
    layout::{modal::Modal, topbar::Topbar},
};

use crate::{
    components::media::calling::CallControl,
    layouts::chats::{
        data::ChatData,
        presentation::{
            chat::{edit_group::EditGroup, group_users::GroupUsers},
            chatbar::get_chatbar,
            messages::get_messages,
        },
    },
};

use common::{
    state::{ui, Action, State},
    warp_runner::{RayGunCmd, WarpCmd},
    WARP_CMD_CH,
};

use common::language::get_local_text;

use uuid::Uuid;
use warp::{crypto::DID, logging::tracing::log};

#[allow(non_snake_case)]
pub fn Compose(cx: Scope) -> Element {
    log::trace!("rendering compose");
    let state = use_shared_state::<State>(cx)?;
    let chat_data = use_state(cx, || -> Option<Rc<ChatData>> { None });

    // todo: add a field to cause this use_future to rerun when a message is sent/deleted/etc
    let active_chat_id = state.read().get_active_chat().map(|x| x.id);
    use_future(cx, &active_chat_id, |conv_id| {
        to_owned![state, chat_data];
        async move {
            while !state.read().initialized {
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            }
            println!("fetching messages for chat_id: {:?}", conv_id);

            let conv_id = match conv_id {
                None => return,
                Some(x) => x,
            };
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            let (tx, rx) = oneshot::channel();
            // todo: use the ChatBehavior to init the FetchMessages command.
            if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::FetchMessages {
                conv_id,
                start_date: None,
                to_fetch: 40,
                rsp: tx,
            })) {
                log::error!("failed to init messages: {e}");
                return;
            }

            let rsp = match rx.await {
                Ok(r) => r,
                Err(e) => {
                    log::error!("failed to send warp command. channel closed. {e}");
                    return;
                }
            };

            match rsp {
                Ok(r) => {
                    println!("got FetchMessagesResponse");
                    chat_data.with_mut(|x| *x = ChatData::get(&state, r.messages));
                }
                Err(e) => {
                    log::error!("FetchMessages command failed: {e}");
                }
            };
        }
    });
    let data = chat_data.get().clone();
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
                controls: cx.render(rsx!(controls::get_controls{
                    data: data2.clone(),
                    show_edit_group: show_edit_group.clone(),
                    show_group_users: show_group_users.clone(),
                    ignore_focus: should_ignore_focus,
                    is_owner: is_owner,
                    is_edit_group: is_edit_group,
                })),
                topbar::get_topbar_children {
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
            Some(_data) =>  rsx!(get_messages{data: _data.clone()}),
        },
        get_chatbar {
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
