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
use futures::StreamExt;
use std::{collections::HashMap, rc::Rc};
use uuid::Uuid;

use crate::layouts::chats::{
    data::{ActiveChatArgs, ChatBehavior, ChatData, MsgRange, ViewInit, DEFAULT_MESSAGES_TO_TAKE},
    ActiveChat,
};

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
                        if !chat_data.read().is_initialized {
                            continue;
                        }
                        let mut data = chat_data.write();
                        data.active_chat.messages.push_back(message);
                        //data.active_chat.chat_behavior.increment_end_idx();
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
pub fn init_chat_data(
    cx: Scope,
    state: &UseSharedState<State>,
    chat_data: &UseSharedState<ChatData>,
    chat_behaviors: &UseSharedState<HashMap<Uuid, ChatBehavior>>,
) {
    let active_chat_id = state.read().get_active_chat().map(|x| x.id);
    use_future(cx, (&active_chat_id), |(conv_id)| {
        to_owned![state, chat_data, chat_behaviors];
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
            let chat_behavior = chat_behaviors
                .read()
                .get(&conv_id)
                .cloned()
                .unwrap_or_default();
            let fetch_mesages_config = chat_behavior.messages_config();
            // todo: save the config during runtime
            if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::FetchMessages {
                conv_id,
                config: fetch_mesages_config,
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
                    let msg_len = r.messages.len();
                    // todo: make the ViewInit and MsgRange dynamic.
                    let ac = ActiveChat::new(ActiveChatArgs {
                        conversation_id: conv_id,
                        messages: r.messages,
                        chat_behavior: ChatBehavior::new(
                            ViewInit::MostRecent,
                            MsgRange::new(0, msg_len),
                        ),
                    });
                    // todo: verify that unwrap_or_default() doesn't cause strange behavior
                    *chat_data.write() = ChatData::get(&state, ac).unwrap_or_default();

                    // todo: copy over the ChatBehavior too
                    *active_chat.write() = ActiveChat::new(ActiveChatArgs {
                        conversation_id: state
                            .read()
                            .get_active_chat()
                            .map(|x| x.id)
                            .unwrap_or_default(),
                        messages: r.messages,
                        chat_behavior: ChatBehavior::default(),
                    });
                }
                Err(e) => {
                    log::error!("FetchMessages command failed: {e}");
                }
            };
        }
    });
}
