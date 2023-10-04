use crate::{
    layouts::chats::{
        data::{ChatData, ScrollTo},
        scripts::{
            self, SCROLL_BOTTOM, SCROLL_TO, SCROLL_TO_MESSAGE, SCROLL_UNREAD, SETUP_CONTEXT_PARENT,
        },
    },
    utils,
};
use common::state::State;
use dioxus_core::Scoped;
use dioxus_hooks::{to_owned, use_effect, Coroutine, UseRef, UseSharedState};
use uuid::Uuid;

use super::NewelyFetchedMessages;

pub fn init_msg_scroll<'a>(
    cx: &'a Scoped,
    chat_data: &UseSharedState<ChatData>,
    eval_provider: &utils::EvalProvider,
    ch: Coroutine<()>,
) {
    let chat_key = chat_data.read().active_chat.key();
    use_effect(cx, &chat_key, |_chat_key| {
        to_owned![eval_provider, ch, chat_data];
        async move {
            // replicate behavior from before refactor
            _ = eval_provider(SETUP_CONTEXT_PARENT);

            let chat_id = chat_data.read().active_chat.id();
            let chat_behavior = chat_data.read().get_chat_behavior(chat_id);
            log::debug!(
                "use_effect for init_msg_scroll {}. scrolling to: {:?}",
                chat_id,
                chat_behavior.view_init.scroll_to
            );
            let scroll_script = match chat_behavior.view_init.scroll_to {
                // if there are unreads, scroll up so first unread is at top of screen
                // todo: if there are more than 40 unread messages, need to fetch more from warp.
                ScrollTo::MostRecent => match chat_data.read().active_chat.unreads() {
                    0 => scripts::SCROLL_TO_END.to_string(),
                    x => {
                        let msg_idx = chat_data
                            .read()
                            .active_chat
                            .messages
                            .all
                            .len()
                            .saturating_sub(x);
                        let msg_id = chat_data
                            .read()
                            .active_chat
                            .messages
                            .all
                            .get(msg_idx)
                            .map(|x| x.inner.id());
                        match msg_id {
                            Some(id) => {
                                scripts::SCROLL_TO_TOP.replace("$MESSAGE_ID", &format!("{id}"))
                            }
                            None => {
                                log::error!("failed to scroll up to top of unread messages");
                                scripts::SCROLL_TO_END.to_string()
                            }
                        }
                    }
                },
                ScrollTo::ScrollUp { view_top } => {
                    scripts::SCROLL_TO_TOP.replace("$MESSAGE_ID", &format!("{view_top}"))
                }
                ScrollTo::ScrollDown { view_bottom } => {
                    scripts::SCROLL_TO_BOTTOM.replace("$MESSAGE_ID", &format!("{view_bottom}"))
                }
            };

            chat_data.write_silent().active_chat.clear_unreads();

            match eval_provider(&scroll_script) {
                Ok(eval) => {
                    if let Err(e) = eval.join().await {
                        log::error!("failed to join eval: {:?}", e);
                    } else {
                        ch.send(());
                    }
                }
                Err(e) => {
                    log::error!("eval failed: {:?}", e);
                }
            }
        }
    });
}

pub fn update_chat_messages<'a>(
    cx: &'a Scoped,
    state: &UseSharedState<State>,
    newely_fetched_messages: &UseRef<Option<NewelyFetchedMessages>>,
) {
    use_effect(cx, (), |_| {
        to_owned![state, newely_fetched_messages];
        async move {
            if let Some(NewelyFetchedMessages {
                conversation_id,
                messages,
                has_more,
            }) = newely_fetched_messages.write_silent().take()
            {
                state
                    .write()
                    .update_chat_messages(conversation_id, messages);
                if !has_more {
                    log::debug!("finished loading chat: {conversation_id}");
                    state.write().finished_loading_chat(conversation_id);
                }
            }
        }
    });
}

pub fn check_message_scroll<'a>(
    cx: &'a Scoped,
    scroll_to: &Option<Uuid>,
    state: &UseSharedState<State>,
    eval: &utils::EvalProvider,
    currently_active: &Option<Uuid>,
) {
    use_effect(cx, scroll_to, |_| {
        to_owned![state, eval, currently_active];
        async move {
            let currently_active = match currently_active {
                Some(r) => r,
                None => return,
            };
            if let Some(uuid) = state.write_silent().check_message_scroll(&currently_active) {
                let _ = eval(&SCROLL_TO_MESSAGE.replace("$UUID", &uuid.to_string()));
            }
        }
    });
}

pub fn scroll_to_bottom<'a>(
    cx: &'a Scoped,
    scroll: Option<i64>,
    eval: &utils::EvalProvider,
    unreads: u32,
    active_chat_id: Uuid,
    prev_chat_id: &UseRef<Uuid>,
) {
    use_effect(cx, &active_chat_id, |id| {
        to_owned![eval, prev_chat_id];
        async move {
            // yes, this check seems like some nonsense. but it eliminates a jitter and if
            // switching out of the chats view ever gets fixed, it would let you scroll up in the active chat,
            // switch to settings or whatnot, then come back to the chats view and not lose your place.
            if *prev_chat_id.read() != id {
                *prev_chat_id.write_silent() = id;
                let script = if let Some(val) = scroll {
                    SCROLL_TO.replace("$VALUE", &val.to_string())
                } else if unreads > 0 {
                    SCROLL_UNREAD.replace("$UNREADS", &unreads.to_string())
                } else {
                    SCROLL_BOTTOM.to_string()
                };
                _ = eval(&script);
            }
            _ = eval(SETUP_CONTEXT_PARENT);
        }
    });
}
