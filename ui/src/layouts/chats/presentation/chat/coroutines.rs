use chrono::{DateTime, Utc};
use common::{
    state::State,
    warp_runner::{
        ui_adapter::{MessageEvent, RayGunEvent},
        FetchMessagesConfig, RayGunCmd, WarpCmd, WarpEvent,
    },
    WARP_CMD_CH, WARP_EVENT_CH,
};
use dioxus::prelude::*;
use futures::channel::oneshot;
use uuid::Uuid;

use crate::layouts::chats::data::{self, ChatData};

pub fn handle_warp_events(
    cx: Scope,
    state: &UseSharedState<State>,
    chat_data: &UseSharedState<ChatData>,
) {
    let active_chat_id = state.read().get_active_chat().map(|x| x.id);
    use_future(cx, (&active_chat_id), |chat_id| {
        to_owned![state, chat_data];
        async move {
            let mut ch = WARP_EVENT_CH.tx.subscribe();
            while let Ok(evt) = ch.recv().await {
                let message_evt = match evt {
                    WarpEvent::Message(evt) => evt,
                    _ => continue,
                };
                let chat_id = match chat_id.as_ref() {
                    Some(x) => *x,
                    None => continue,
                };

                match message_evt {
                    MessageEvent::Received {
                        conversation_id,
                        message,
                    }
                    | MessageEvent::Sent {
                        conversation_id,
                        message,
                    } => {
                        if conversation_id != chat_id {
                            continue;
                        }
                        if chat_data
                            .write_silent()
                            .new_message(conversation_id, message)
                        {
                            chat_data.write();
                        }
                    }
                    MessageEvent::Edited {
                        conversation_id,
                        message,
                    } => {}
                    MessageEvent::Deleted {
                        conversation_id,
                        message_id,
                    } => {}
                    MessageEvent::MessageReactionAdded { message } => {}
                    MessageEvent::MessageReactionRemoved { message } => {}
                    _ => continue,
                }
            }
        }
    });
}

// any use_future should be in the coroutines file to prevent a naming conflict with the futures crate.
pub fn init_chat_data<'a>(
    cx: &Scoped<'a>,
    state: &'a UseSharedState<State>,
    chat_data: &'a UseSharedState<ChatData>,
) -> &'a UseFuture<()> {
    let active_chat_id = state.read().get_active_chat().map(|x| x.id);
    use_future(cx, (&active_chat_id), |(conv_id)| {
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

            match chat_data
                .read()
                .get_chat_behavior(conv_id)
                .messages_config()
            {
                FetchMessagesConfig::MostRecent { limit } => {
                    fetch_most_recent(chat_data.write(), state.read(), conv_id, limit).await;
                }
                FetchMessagesConfig::Window { center, half_size } => {
                    fetch_window(chat_data.write(), state.read(), conv_id, center, half_size).await;
                }
                _ => unreachable!(),
            }
        }
    })
}

async fn fetch_window<'a>(
    mut chat_data: RefMut<'a, ChatData>,
    state: Ref<'a, State>,
    conv_id: Uuid,
    date: DateTime<Utc>,
    half_size: usize,
) {
    let mut messages = vec![];
    let has_more_before: bool;
    let has_more_after: bool;

    let warp_cmd_tx = WARP_CMD_CH.tx.clone();
    let (tx, rx) = oneshot::channel();

    if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::FetchMessages {
        conv_id,
        config: FetchMessagesConfig::Earlier {
            start_date: date,
            limit: half_size,
        },
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
            has_more_before = r.has_more;
            messages = r.messages;
        }
        Err(e) => {
            log::error!("FetchMessages command failed: {e}");
            return;
        }
    };

    let (tx, rx) = oneshot::channel();

    if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::FetchMessages {
        conv_id,
        config: FetchMessagesConfig::Later {
            start_date: date,
            limit: half_size,
        },
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
        Ok(mut r) => {
            has_more_after = r.has_more;
            if let Some(msg) = r.messages.first() {
                if msg.inner.id() == messages.last().map(|x| x.inner.id()).unwrap_or_default() {
                    messages.pop();
                }
                messages.append(&mut r.messages);
            }
        }
        Err(e) => {
            log::error!("FetchMessages command failed: {e}");
            return;
        }
    };

    let mut chat_behavior = chat_data.get_chat_behavior(conv_id);
    chat_behavior.on_scroll_end = if has_more_after {
        data::ScrollBehavior::FetchMore
    } else {
        data::ScrollBehavior::DoNothing
    };

    chat_behavior.on_scroll_top = if has_more_before {
        data::ScrollBehavior::FetchMore
    } else {
        data::ScrollBehavior::DoNothing
    };

    chat_data.set_active_chat(&state, &conv_id, chat_behavior, messages);
}

async fn fetch_most_recent<'a>(
    mut chat_data: RefMut<'a, ChatData>,
    state: Ref<'a, State>,
    conv_id: Uuid,
    limit: usize,
) {
    let warp_cmd_tx = WARP_CMD_CH.tx.clone();
    let (tx, rx) = oneshot::channel();
    let mut chat_behavior = chat_data.get_chat_behavior(conv_id);

    // todo: save the config during runtime
    if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::FetchMessages {
        conv_id,
        config: FetchMessagesConfig::MostRecent { limit },
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
            println!("got FetchMessagesResponse to init chat {conv_id}");
            chat_behavior.on_scroll_end = data::ScrollBehavior::DoNothing;
            chat_behavior.on_scroll_top = if r.has_more {
                data::ScrollBehavior::FetchMore
            } else {
                data::ScrollBehavior::DoNothing
            };
            chat_data.set_active_chat(&state, &conv_id, chat_behavior, r.messages);
        }
        Err(e) => {
            log::error!("FetchMessages command failed: {e}");
        }
    };
}
