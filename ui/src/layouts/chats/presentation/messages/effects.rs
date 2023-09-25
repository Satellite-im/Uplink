use crate::{
    layouts::chats::scripts::{
        SCROLL_BOTTOM, SCROLL_TO, SCROLL_TO_MESSAGE, SCROLL_UNREAD, SETUP_CONTEXT_PARENT,
    },
    utils,
};
use common::state::State;
use dioxus_core::Scoped;
use dioxus_hooks::{to_owned, use_effect, Coroutine, UseRef, UseSharedState};
use uuid::Uuid;

use super::{get_messagesProps, NewelyFetchedMessages};

pub fn init_msg_scroll<'a>(
    cx: &'a Scoped<'a, get_messagesProps>,
    eval_provider: &utils::EvalProvider,
    ch: Coroutine<Uuid>,
    active_chat_id: Uuid,
    scroll_script: String,
) {
    use_effect(cx, (&active_chat_id), |(chat_id)| {
        to_owned![eval_provider, ch, scroll_script];
        async move {
            match eval_provider(&scroll_script) {
                Ok(eval) => {
                    if let Err(e) = eval.join().await {
                        log::error!("failed to join eval: {:?}", e);
                    } else {
                        ch.send(chat_id);
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
    cx: &'a Scoped<'a, get_messagesProps>,
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
    cx: &'a Scoped<'a, get_messagesProps>,
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
    cx: &'a Scoped<'a, get_messagesProps>,
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
