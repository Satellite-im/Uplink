use std::path::PathBuf;

use common::{
    state::{Action, State},
    warp_runner::{RayGunCmd, WarpCmd},
    WARP_CMD_CH,
};
use dioxus::prelude::*;
use futures::{channel::oneshot, StreamExt};
use uuid::Uuid;
use warp::raygun::Location;

use crate::layouts::chats::data::{self, ChatProps, DEFAULT_MESSAGES_TO_TAKE};

use super::ChatInput;

pub fn get_msg_ch<'a>(
    cx: &Scoped<'a, ChatProps>,
    chat_data: &UseSharedState<data::ChatData>,
    state: &UseSharedState<State>,
) -> Coroutine<(Vec<String>, Uuid, Option<Uuid>, Option<Uuid>)> {
    use_coroutine(cx, |mut rx: UnboundedReceiver<ChatInput>| {
        to_owned![state];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some((msg, conv_id, ui_msg_id, reply)) = rx.next().await {
                let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();
                let attachments = state
                    .read()
                    .get_active_chat()
                    .map(|f| f.files_attached_to_send)
                    .unwrap_or_default();
                let msg_clone = msg.clone();
                let cmd = match reply {
                    Some(reply_to) => RayGunCmd::Reply {
                        conv_id,
                        reply_to,
                        msg,
                        attachments,
                        rsp: tx,
                    },
                    None => RayGunCmd::SendMessage {
                        conv_id,
                        msg,
                        attachments,
                        ui_msg_id,
                        rsp: tx,
                    },
                };
                let attachments = state
                    .read()
                    .get_active_chat()
                    .map(|f| f.files_attached_to_send)
                    .unwrap_or_default();
                state
                    .write_silent()
                    .mutate(Action::ClearChatAttachments(conv_id));
                let attachment_files: Vec<String> = attachments
                    .iter()
                    .map(|p| {
                        let pathbuf = match p {
                            Location::Disk { path } => path.clone(),
                            Location::Constellation { path } => PathBuf::from(path),
                        };
                        pathbuf
                            .file_name()
                            .map_or_else(String::new, |ostr| ostr.to_string_lossy().to_string())
                    })
                    .collect();
                if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(cmd)) {
                    log::error!("failed to send warp command: {}", e);
                    state.write().decrement_outgoing_messages(
                        conv_id,
                        msg_clone,
                        attachment_files,
                        ui_msg_id,
                    );
                    continue;
                }

                let rsp = rx.await.expect("command canceled");
                if let Err(e) = rsp {
                    log::error!("failed to send message: {}", e);
                    state.write().decrement_outgoing_messages(
                        conv_id,
                        msg_clone,
                        attachment_files,
                        ui_msg_id,
                    );
                }
            }
        }
    })
    .clone()
}

pub fn get_scroll_ch<'a>(
    cx: &Scoped<'a, ChatProps>,
    chat_data: &UseSharedState<data::ChatData>,
    state: &UseSharedState<State>,
) -> Coroutine<Uuid> {
    use_coroutine(cx, |mut rx: UnboundedReceiver<Uuid>| {
        to_owned![chat_data, state];
        async move {
            while let Some(conv_id) = rx.next().await {
                match crate::layouts::chats::presentation::chat::coroutines::fetch_most_recent(
                    conv_id,
                    DEFAULT_MESSAGES_TO_TAKE,
                )
                .await
                {
                    Ok((messages, behavior)) => {
                        log::debug!("re-init messages with most recent");
                        chat_data.write().set_active_chat(
                            &state.read(),
                            &conv_id,
                            behavior,
                            messages,
                        );
                    }
                    Err(e) => log::error!("{e}"),
                }
            }
        }
    })
    .clone()
}
