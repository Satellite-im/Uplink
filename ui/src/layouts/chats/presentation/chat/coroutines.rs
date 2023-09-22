use std::rc::Rc;

use common::{
    state::State,
    warp_runner::{RayGunCmd, WarpCmd},
    WARP_CMD_CH,
};
use dioxus::prelude::*;
use futures::channel::oneshot;

use crate::layouts::chats::data::ChatData;

// any use_future should be in the coroutines file to prevent a naming conflict with the futures crate.
pub fn init_chat_data(
    cx: Scope,
    state: &UseSharedState<State>,
    chat_data: &UseState<Option<Rc<ChatData>>>,
) {
    // todo: add a field to cause this use_future to rerun when a message is sent/deleted/etc
    let active_chat_id = state.read().get_active_chat().map(|x| x.id);
    let active_chat_behavior = state.read().get_active_chat().map(|x| x.chat_behavior);
    use_future(
        cx,
        (&active_chat_id, &active_chat_behavior),
        |(conv_id, behavior)| {
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
                    chat_behavior: behavior.unwrap_or_default(),
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
        },
    );
}
