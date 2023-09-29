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
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            let (tx, rx) = oneshot::channel();
            let mut chat_behavior = chat_data.read().get_chat_behavior(conv_id);
            // todo: save the config during runtime
            if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::FetchMessages {
                conv_id,
                config: chat_behavior.messages_config(),
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
                    match chat_behavior.view_init.scroll_to.clone() {
                        data::ScrollTo::MostRecent => {
                            if !r.has_more {
                                chat_behavior.on_scroll_top = data::ScrollBehavior::DoNothing;
                            }
                            chat_behavior.on_scroll_end = data::ScrollBehavior::DoNothing;
                        }
                        data::ScrollTo::ScrollUp { .. } => {
                            if !r.has_more {
                                chat_behavior.on_scroll_top = data::ScrollBehavior::DoNothing;
                            }
                            chat_behavior.on_scroll_end = data::ScrollBehavior::FetchMore;
                        }
                        data::ScrollTo::ScrollDown { .. } => {
                            if !r.has_more {
                                chat_behavior.on_scroll_end = data::ScrollBehavior::DoNothing;
                            }
                            chat_behavior.on_scroll_top = data::ScrollBehavior::FetchMore;
                        }
                    }

                    chat_data.write().set_active_chat(
                        &state.read(),
                        &conv_id,
                        chat_behavior,
                        r.messages,
                    );
                }
                Err(e) => {
                    log::error!("FetchMessages command failed: {e}");
                }
            };
        }
    })
}
