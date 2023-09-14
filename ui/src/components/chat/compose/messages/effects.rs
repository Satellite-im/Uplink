use std::rc::Rc;

use common::state::State;
use dioxus::prelude::{EvalError, UseEval};
use dioxus_core::Scoped;
use dioxus_hooks::{to_owned, use_effect, UseRef, UseSharedState};
use uuid::Uuid;

use crate::components::chat::compose::messages::{
    SCROLL_BOTTOM, SCROLL_TO, SCROLL_UNREAD, SETUP_CONTEXT_PARENT,
};

use super::get_messagesProps;

pub fn check_message_scroll<'a>(
    cx: &'a Scoped<'a, get_messagesProps>,
    scroll_to: &Option<Uuid>,
    state: &UseSharedState<State>,
    eval: &Rc<dyn Fn(&str) -> Result<UseEval, EvalError>>,
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
                let _ = eval(
                    &include_str!("../../scroll_to_message.js").replace("$UUID", &uuid.to_string()),
                );
            }
        }
    });
}

pub fn scroll_to_bottom<'a>(
    cx: &'a Scoped<'a, get_messagesProps>,
    scroll: Option<i64>,
    eval: &Rc<dyn Fn(&str) -> Result<UseEval, EvalError>>,
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
