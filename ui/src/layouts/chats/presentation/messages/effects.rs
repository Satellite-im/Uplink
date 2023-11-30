use crate::{
    layouts::chats::{
        data::{ChatData, ScrollBtn, ScrollTo},
        presentation::messages::{READ_SCROLL, SCROLL_BTN_THRESHOLD},
        scripts::{self, SETUP_CONTEXT_PARENT},
    },
    utils,
};
use dioxus_core::ScopeState;
use dioxus_hooks::{to_owned, use_effect, Coroutine, UseSharedState};

pub fn init_msg_scroll(
    cx: &ScopeState,
    chat_data: &UseSharedState<ChatData>,
    eval_provider: &utils::EvalProvider,
    scroll_btn: &UseSharedState<ScrollBtn>,
    ch: Coroutine<()>,
) {
    let chat_key = chat_data.read().active_chat.key();
    use_effect(cx, &chat_key, |_chat_key| {
        to_owned![eval_provider, ch, chat_data, scroll_btn];
        async move {
            // replicate behavior from before refactor
            if let Ok(eval) = eval_provider(SETUP_CONTEXT_PARENT) {
                let _ = eval.join().await;
            }

            let chat_id = chat_data.read().active_chat.id();
            let chat_behavior = chat_data.read().get_chat_behavior(chat_id);
            log::trace!(
                "use_effect for init_msg_scroll {}. behavior: {:?}",
                chat_id,
                chat_behavior
            );
            let unreads = chat_data.read().active_chat.unreads();

            let scroll_script = match chat_behavior.view_init.scroll_to {
                // if there are unreads, scroll up so first unread is at top of screen
                // todo: if there are more than 40 unread messages, need to fetch more from warp.
                ScrollTo::MostRecent => {
                    if unreads > 0 {
                        chat_data.write_silent().active_chat.clear_unreads();
                    }
                    let msg_idx = chat_data
                        .read()
                        .active_chat
                        .messages
                        .all
                        .len()
                        .saturating_sub(unreads + 1);
                    let msg_id = chat_data
                        .read()
                        .active_chat
                        .messages
                        .all
                        .get(msg_idx)
                        .map(|x| x.inner.id());
                    match msg_id {
                        Some(id) => {
                            scripts::SCROLL_TO_BOTTOM.replace("$MESSAGE_ID", &format!("{id}"))
                        }
                        None => {
                            log::error!("failed to init message scroll");
                            //scripts::SCROLL_TO_END.to_string()
                            "return done;".to_string()
                        }
                    }
                }
                ScrollTo::ScrollUp { view_top } => {
                    scripts::SCROLL_TO_TOP.replace("$MESSAGE_ID", &format!("{view_top}"))
                }
                ScrollTo::ScrollDown { view_bottom } => {
                    scripts::SCROLL_TO_BOTTOM.replace("$MESSAGE_ID", &format!("{view_bottom}"))
                }
            };

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

            if let Ok(val) = eval_provider(READ_SCROLL) {
                if let Ok(result) = val.join().await {
                    let scroll = result.as_i64().unwrap_or_default();
                    let show = scroll < SCROLL_BTN_THRESHOLD;
                    let update = show != scroll_btn.read().get(chat_id);
                    // Only update if the value has changed
                    if update {
                        if show {
                            scroll_btn.write().set(chat_id);
                        } else {
                            scroll_btn.write().clear(chat_id);
                        }
                    }
                }
            }
        }
    });
}
