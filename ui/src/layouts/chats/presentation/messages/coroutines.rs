use std::time::Duration;

use common::{
    language::get_local_text_with_args,
    state::{Action, State, ToastNotification},
    warp_runner::{FetchMessagesConfig, FetchMessagesResponse, RayGunCmd, WarpCmd},
    WARP_CMD_CH,
};

use dioxus_core::ScopeState;
use dioxus_hooks::{to_owned, use_coroutine, Coroutine, UnboundedReceiver, UseSharedState};
use futures::{channel::oneshot, pin_mut, StreamExt};

use uuid::Uuid;
use warp::raygun::{PinState, ReactionState};

use crate::{
    layouts::chats::{
        data::{self, ChatBehavior, ChatData, JsMsg, ScrollBtn, DEFAULT_MESSAGES_TO_TAKE},
        scripts::OBSERVER_SCRIPT,
    },
    utils::download::get_download_path,
};

use super::{DownloadTracker, MessagesCommand};

pub fn hangle_msg_scroll(
    cx: &ScopeState,
    eval_provider: &crate::utils::EvalProvider,
    chat_data: &UseSharedState<ChatData>,
    scroll_btn: &UseSharedState<ScrollBtn>,
) -> Coroutine<()> {
    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<()>| {
        to_owned![eval_provider, chat_data, scroll_btn];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();

            // don't begin the coroutine until use_eval sends a command over the channel.
            while rx.next().await.is_some() {
                // this is basically a goto
                'CONFIGURE_EVAL: loop {
                    // if there are no messages to render, don't bother with the javascript.
                    if chat_data.read().active_chat.messages.top().is_none() {
                        break 'CONFIGURE_EVAL;
                    }

                    chat_data
                        .write_silent()
                        .active_chat
                        .messages
                        .displayed
                        .clear();

                    let conv_id = chat_data.read().active_chat.id();
                    let conv_key = chat_data.read().active_chat.key();
                    let behavior = chat_data.read().get_chat_behavior(conv_id);

                    let should_send_top_evt =
                        behavior.on_scroll_top != data::ScrollBehavior::DoNothing;
                    let should_send_bottom_evt =
                        behavior.on_scroll_end != data::ScrollBehavior::DoNothing;

                    let bottom_msg_id: Uuid = chat_data
                        .read()
                        .active_chat
                        .messages
                        .bottom()
                        .unwrap_or(Uuid::nil());
                    let top_msg_id: Uuid = chat_data
                        .read()
                        .active_chat
                        .messages
                        .top()
                        .unwrap_or(Uuid::nil());

                    log::debug!(
                        "top msg is: {}, bottom msg is: {}",
                        top_msg_id,
                        bottom_msg_id
                    );

                    let mut observer_script = OBSERVER_SCRIPT.replace(
                        "$SEND_TOP_EVENT",
                        if should_send_top_evt { "1" } else { "0" },
                    );
                    observer_script = observer_script.replace(
                        "$SEND_BOTTOM_EVENT",
                        if should_send_bottom_evt { "1" } else { "0" },
                    );
                    observer_script =
                        observer_script.replace("$CONVERSATION_KEY", &conv_key.to_string());
                    observer_script =
                        observer_script.replace("$TOP_MSG_ID", &top_msg_id.to_string());
                    observer_script =
                        observer_script.replace("$BOTTOM_MSG_ID", &bottom_msg_id.to_string());

                    let eval = match eval_provider(&observer_script) {
                        Ok(r) => r,
                        Err(e) => {
                            log::error!("use eval failed: {:?}", e);
                            return;
                        }
                    };

                    // not sure if it's safe to call eval.recv() in a select! statement. turning it into something
                    // which should definitely work for that.
                    let _key = chat_data.read().active_chat.key();
                    let eval_stream = async_stream::stream! {
                        let mut should_break = false;
                        while !should_break {
                            match eval.recv().await {
                                Ok(s) => match serde_json::from_str::<JsMsg>(s.as_str().unwrap_or_default()) {
                                    Ok(msg) => {
                                        // note: if something is wrong with messages, the first thing you should do is to uncomment this log
                                        // log::debug!("{:?}", msg);
                                        // perhaps this is redundant now that the IntersectionObserver self terminates.
                                        let is_evt_valid = matches!(msg, JsMsg::Top { key }
                                            | JsMsg::Bottom { key }
                                            | JsMsg::Add { key, .. }
                                            | JsMsg::Remove { key, .. } if key ==  _key);

                                        if !is_evt_valid {
                                            log::warn!("received js event from wrong conversation");
                                            continue;
                                        }
                                        should_break = matches!(msg, JsMsg::Top{ .. } | JsMsg::Bottom { .. });
                                        yield msg;
                                    },
                                    Err(e) => {
                                        log::error!("failed to deserialize message: {}: {}", s, e);
                                        break;
                                    }
                                }
                                Err(e) => {
                                    log::error!("error receiving from js: {e:?}");
                                    break;
                                }
                            }
                        }
                    };
                    pin_mut!(eval_stream);

                    'HANDLE_EVAL: loop {
                        tokio::select! {
                            opt = rx.next() => {
                                match opt {
                                    Some(_) => {
                                        log::debug!("coroutine restart triggered");
                                        continue 'CONFIGURE_EVAL;
                                    }
                                    None => {
                                        // failed to read from stream. use_coroutine is probably done for.
                                        log::warn!("failed to read from coroutine ch for handle_msg_scroll");
                                        return;
                                    }
                                }
                            },
                            res = eval_stream.next() => match res {
                                Some(msg) => match msg {
                                    JsMsg::Add { msg_id, .. } => {
                                        if chat_data.write_silent().add_message_to_view(conv_id, msg_id) {
                                            continue 'HANDLE_EVAL;
                                        }
                                        let chat_behavior = chat_data.read().get_chat_behavior(conv_id);
                                        // a message can be added to the top of the view without removing a message from the bottom of the view.
                                        // need to explicitly compare the bottom of messages.all and messages.displayed
                                        if chat_data.read().get_bottom_of_view(conv_id).map(|pm|  pm.message_id) == chat_data.read().active_chat.messages.bottom(){
                                            // have to check on_scroll_end in case the user scrolled up and switched chats.
                                            if chat_behavior.on_scroll_end == data::ScrollBehavior::DoNothing && scroll_btn.read().get(conv_id) {
                                                scroll_btn.write().clear(conv_id);
                                                log::trace!("clearing scroll_btn");

                                            }
                                        } else if !scroll_btn.read().get(conv_id) {
                                            scroll_btn.write().set(conv_id);
                                            log::trace!("setting scroll_btn");
                                        }
                                    },
                                    JsMsg::Remove { msg_id, .. } => {
                                        let _ = chat_data.write_silent().remove_message_from_view(conv_id, msg_id);
                                    }
                                    JsMsg::Top { .. } => {
                                        log::debug!("top reached");
                                        // send uuid/timestamp of oldest message to WarpRunner to process top event
                                        // receive the new messages and if there are more in that direction
                                        if !should_send_top_evt {
                                            log::error!("top event received when it shouldn't have fired");
                                            continue 'HANDLE_EVAL;
                                        }

                                        let msg = match chat_data.read().get_top_of_view(conv_id) {
                                            Some(x) => x,
                                            None => {
                                                log::error!("no messages at top of view");
                                                let mut behavior = chat_data.read().get_chat_behavior(conv_id);
                                                behavior.on_scroll_top = data::ScrollBehavior::DoNothing;
                                                chat_data.write_silent().set_chat_behavior(conv_id, behavior);
                                                continue 'HANDLE_EVAL;
                                            }
                                        };

                                        let (tx, rx) = oneshot::channel();
                                        let cmd = RayGunCmd::FetchMessages{
                                            conv_id,
                                            config: FetchMessagesConfig::Earlier { start_date: msg.date, limit: DEFAULT_MESSAGES_TO_TAKE / 2 },
                                            rsp: tx
                                        };

                                        if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(cmd)) {
                                            log::error!("failed to send warp cmd: {e}");
                                            tokio::time::sleep(Duration::from_secs(1)).await;
                                            continue 'HANDLE_EVAL;
                                        }

                                        let rsp = match rx.await {
                                            Ok(r) => r,
                                            Err(e) => {
                                                log::error!("failed to send warp command. channel closed. {e}");
                                                tokio::time::sleep(Duration::from_secs(1)).await;
                                                continue 'HANDLE_EVAL;
                                            }
                                        };

                                        match rsp {
                                            Ok(FetchMessagesResponse{ messages, has_more }) => {
                                                let new_messages = messages.len();
                                                chat_data.write().top_reached(conv_id);
                                                chat_data.write().insert_messages(conv_id, messages);
                                                let mut behavior = chat_data.read().get_chat_behavior(conv_id);
                                                behavior.on_scroll_top = if has_more { data::ScrollBehavior::FetchMore } else { data::ScrollBehavior::DoNothing };
                                                if new_messages > 0 {
                                                    behavior.on_scroll_end = data::ScrollBehavior::FetchMore;
                                                }

                                                log::debug!("fetched {new_messages} messages. new behavior: {:?}", behavior);
                                                chat_data.write().set_chat_behavior(conv_id, behavior);
                                                chat_data.write().active_chat.new_key();
                                                break 'HANDLE_EVAL;
                                            },
                                            Err(e) => {
                                                log::error!("FetchMessages command failed: {e}");
                                                //tokio::time::sleep(Duration::from_secs(1)).await;
                                                continue 'HANDLE_EVAL;
                                            }
                                        }
                                    }
                                    JsMsg::Bottom { .. } => {
                                        log::debug!("bottom reached");
                                        // send uuid/timestamp of most recent message to WarpRunner to process top event
                                        // receive the new messages and if there are more in that direction
                                        if !should_send_bottom_evt {
                                            log::error!("bottom event received when it shouldn't have fired");
                                            continue 'HANDLE_EVAL;
                                        }

                                        let msg = match chat_data.read().get_bottom_of_view(conv_id) {
                                            Some(x) => x,
                                            None => {
                                                log::error!("no messages at bottom of view");
                                                chat_data.write_silent().set_chat_behavior(conv_id, ChatBehavior::default());
                                                continue 'HANDLE_EVAL;
                                            }
                                        };

                                        let (tx, rx) = oneshot::channel();
                                        let cmd = RayGunCmd::FetchMessages{
                                            conv_id,
                                            config: FetchMessagesConfig::Later { start_date: msg.date, limit: DEFAULT_MESSAGES_TO_TAKE / 2},
                                            rsp: tx
                                        };

                                        if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(cmd)) {
                                            log::error!("failed to send warp cmd: {e}");
                                            tokio::time::sleep(Duration::from_secs(1)).await;
                                            continue 'HANDLE_EVAL;
                                        }

                                        let rsp = match rx.await {
                                            Ok(r) => r,
                                            Err(e) => {
                                                log::error!("failed to send warp command. channel closed. {e}");
                                                tokio::time::sleep(Duration::from_secs(1)).await;
                                                continue 'HANDLE_EVAL;
                                            }
                                        };

                                        match rsp {
                                            Ok(FetchMessagesResponse{ messages, has_more }) => {
                                                let new_messages = messages.len();
                                                chat_data.write().bottom_reached(conv_id);
                                                chat_data.write().insert_messages(conv_id, messages);
                                                chat_data.write().active_chat.new_key();
                                                let mut behavior = chat_data.read().get_chat_behavior(conv_id);
                                                if !has_more {
                                                    // remove extra messages from the list and return to ScrollInit::MostRecent
                                                    chat_data.write().reset_messages(conv_id);
                                                    scroll_btn.write().clear(conv_id);
                                                } else {
                                                    behavior.on_scroll_top = data::ScrollBehavior::FetchMore;
                                                    behavior.on_scroll_end = if has_more { data::ScrollBehavior::FetchMore } else { data::ScrollBehavior::DoNothing };
                                                    chat_data.write().set_chat_behavior(conv_id, behavior.clone());
                                                }

                                                log::debug!("fetched {new_messages} messages. new behavior: {:?}", behavior);
                                                break 'HANDLE_EVAL;
                                            },
                                            Err(e) => {
                                                log::error!("FetchMessages command failed: {e}");
                                                tokio::time::sleep(Duration::from_secs(1)).await;
                                                continue 'HANDLE_EVAL;
                                            }
                                        }
                                    }
                                }
                                None => {
                                    log::info!("the evaluator broke in handle_msg_scroll");
                                    // if desired, call active_chat.new_key() to restart the observer
                                    break 'HANDLE_EVAL;
                                }
                            },
                        }
                    } // HANDLE_EVAL
                    break;
                } // CONFIGURE_EVAL
            } // while rx.next().await.is_some()
        } // async move
    });

    ch.clone()
}

pub fn fetch_later_ch(
    cx: &ScopeState,
    chat_data: &UseSharedState<data::ChatData>,
    scroll_btn: &UseSharedState<ScrollBtn>,
) -> Coroutine<Uuid> {
    use_coroutine(cx, |mut rx: UnboundedReceiver<Uuid>| {
        to_owned![chat_data, scroll_btn];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(conv_id) = rx.next().await {
                let opt = chat_data.read().get_bottom_of_view(conv_id);
                let msg = match opt {
                    Some(x) => x,
                    None => {
                        log::error!("no messages at bottom of view");
                        chat_data
                            .write_silent()
                            .set_chat_behavior(conv_id, ChatBehavior::default());
                        continue;
                    }
                };

                let (tx, rx) = oneshot::channel();
                let cmd = RayGunCmd::FetchMessages {
                    conv_id,
                    config: FetchMessagesConfig::Later {
                        start_date: msg.date,
                        limit: DEFAULT_MESSAGES_TO_TAKE / 2,
                    },
                    rsp: tx,
                };

                if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(cmd)) {
                    log::error!("failed to send warp cmd: {e}");
                    continue;
                }

                let rsp = match rx.await {
                    Ok(r) => r,
                    Err(e) => {
                        log::error!("failed to send warp command. channel closed. {e}");
                        continue;
                    }
                };

                match rsp {
                    Ok(FetchMessagesResponse { messages, has_more }) => {
                        let new_messages = messages.len();
                        chat_data.write().bottom_reached(conv_id);
                        chat_data.write().insert_messages(conv_id, messages);
                        chat_data.write().active_chat.new_key();
                        let mut behavior = chat_data.read().get_chat_behavior(conv_id);
                        if !has_more {
                            // remove extra messages from the list and return to ScrollInit::MostRecent
                            chat_data.write().reset_messages(conv_id);
                            scroll_btn.write().clear(conv_id);
                        } else {
                            behavior.on_scroll_top = data::ScrollBehavior::FetchMore;
                            behavior.on_scroll_end = if has_more {
                                data::ScrollBehavior::FetchMore
                            } else {
                                data::ScrollBehavior::DoNothing
                            };
                            chat_data
                                .write()
                                .set_chat_behavior(conv_id, behavior.clone());
                        }
                        log::debug!(
                            "fetched {new_messages} messages. new behavior: {:?}",
                            behavior
                        );
                        continue;
                    }
                    Err(e) => {
                        log::error!("FetchMessages command failed: {e}");
                        continue;
                    }
                }
            }
        }
    })
    .clone()
}

pub fn handle_warp_commands(
    cx: &ScopeState,
    state: &UseSharedState<State>,
    pending_downloads: &UseSharedState<DownloadTracker>,
) -> Coroutine<MessagesCommand> {
    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<MessagesCommand>| {
        to_owned![state, pending_downloads];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(cmd) = rx.next().await {
                match cmd {
                    MessagesCommand::React((user, message, emoji)) => {
                        let (tx, rx) = futures::channel::oneshot::channel();
                        let reaction_state =
                            match message.reactions().iter().find(|x| x.emoji() == emoji) {
                                Some(reaction) if reaction.users().contains(&user) => {
                                    ReactionState::Remove
                                }
                                _ => ReactionState::Add,
                            };
                        if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::React {
                            conversation_id: message.conversation_id(),
                            message_id: message.id(),
                            reaction_state,
                            emoji: emoji.clone(),
                            rsp: tx,
                        })) {
                            log::error!("failed to send warp command: {}", e);
                            continue;
                        }

                        let res = rx.await.expect("command canceled");
                        match res {
                            Ok(_) => state.write().mutate(Action::AddReaction(
                                message.conversation_id(),
                                message.id(),
                                emoji,
                            )),
                            Err(e) => {
                                log::error!("failed to add/remove reaction: {}", e);
                            }
                        }
                    }
                    MessagesCommand::DeleteMessage { conv_id, msg_id } => {
                        let (tx, rx) = futures::channel::oneshot::channel();
                        if let Err(e) =
                            warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::DeleteMessage {
                                conv_id,
                                msg_id,
                                rsp: tx,
                            }))
                        {
                            log::error!("failed to send warp command: {}", e);
                            continue;
                        }

                        let res = rx.await.expect("command canceled");
                        if let Err(e) = res {
                            log::error!("failed to delete message: {}", e);
                        }
                    }
                    MessagesCommand::DownloadAttachment {
                        conv_id,
                        msg_id,
                        file,
                        file_path_to_download,
                    } => {
                        let (temp_file_path, on_finish) = get_download_path(file_path_to_download);
                        let (tx, rx) = futures::channel::oneshot::channel();
                        if let Err(e) =
                            warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::DownloadAttachment {
                                conv_id,
                                msg_id,
                                file_name: file.name(),
                                file_path_to_download: temp_file_path,
                                rsp: tx,
                            }))
                        {
                            log::error!("failed to send warp command: {}", e);
                            state.write().mutate(Action::AddToastNotification(
                                ToastNotification::init(
                                    "".into(),
                                    get_local_text_with_args(
                                        "files.download-failed",
                                        vec![("file", file.name())],
                                    ),
                                    None,
                                    2,
                                ),
                            ));
                            if let Some(conv) = pending_downloads.write().get_mut(&conv_id) {
                                conv.remove(&file);
                            }
                            continue;
                        }

                        let res = rx.await.expect("command canceled");
                        match res {
                            Ok(mut stream) => {
                                while let Some(p) = stream.next().await {
                                    log::debug!("{p:?}");
                                }
                                state.write().mutate(Action::AddToastNotification(
                                    ToastNotification::init(
                                        "".into(),
                                        get_local_text_with_args(
                                            "files.download-success",
                                            vec![("file", file.name())],
                                        ),
                                        None,
                                        2,
                                    ),
                                ));
                                on_finish.await
                            }
                            Err(e) => {
                                state.write().mutate(Action::AddToastNotification(
                                    ToastNotification::init(
                                        "".into(),
                                        get_local_text_with_args(
                                            "files.download-failed",
                                            vec![("file", file.name())],
                                        ),
                                        None,
                                        2,
                                    ),
                                ));
                                log::error!("failed to download attachment: {}", e);
                            }
                        }
                        if let Some(conv) = pending_downloads.write().get_mut(&conv_id) {
                            conv.remove(&file);
                        }
                    }
                    MessagesCommand::EditMessage {
                        conv_id,
                        msg_id,
                        msg,
                    } => {
                        let (tx, rx) = futures::channel::oneshot::channel();
                        if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::EditMessage {
                            conv_id,
                            msg_id,
                            msg,
                            rsp: tx,
                        })) {
                            log::error!("failed to send warp command: {}", e);
                            continue;
                        }

                        let res = rx.await.expect("command canceled");
                        if let Err(e) = res {
                            log::error!("failed to edit message: {}", e);
                        }
                    }
                    MessagesCommand::Pin(msg) => {
                        let (tx, rx) = futures::channel::oneshot::channel();
                        let pinstate = if msg.pinned() {
                            PinState::Unpin
                        } else {
                            PinState::Pin
                        };
                        if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::Pin {
                            conversation_id: msg.conversation_id(),
                            message_id: msg.id(),
                            pinstate,
                            rsp: tx,
                        })) {
                            log::error!("failed to send warp command: {}", e);
                            continue;
                        }

                        let res = rx.await.expect("command canceled");
                        if let Err(e) = res {
                            log::error!("failed to pin message: {}", e);
                        }
                    }
                }
            }
        }
    });
    ch.clone()
}
