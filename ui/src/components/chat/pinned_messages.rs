use common::{
    state::{Chat, State},
    warp_runner::{ui_adapter, RayGunCmd, WarpCmd},
    WARP_CMD_CH,
};
use dioxus::prelude::*;

use futures::StreamExt;
use uuid::Uuid;
use warp::logging::tracing::log;

#[derive(Props, Eq, PartialEq)]
pub struct Props {
    #[props(!optional)]
    active_chat: Option<Chat>,
}

#[allow(non_snake_case)]
pub fn PinnedMessages(cx: Scope<Props>) -> Element {
    log::trace!("rendering pinned_messages");
    let _state = use_shared_state::<State>(cx)?;
    let _loading = use_state(cx, || true);
    let newely_fetched_messages: &UseRef<Option<(Uuid, Vec<ui_adapter::Message>, bool)>> =
        use_ref(cx, || None);
    let pinned_messages: &UseRef<Vec<ui_adapter::Message>> = use_ref(cx, || vec![]);

    if let Some((_, mut m, _)) = newely_fetched_messages.write_silent().take() {
        pinned_messages.write().append(m.as_mut());
    }

    let chat = match &cx.props.active_chat {
        Some(c) => c,
        None => return cx.render(rsx!(())),
    };

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<(Uuid, usize, usize)>| {
        to_owned![newely_fetched_messages];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some((conv_id, to_fetch, current_len)) = rx.next().await {
                let (tx, rx) = futures::channel::oneshot::channel();
                if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::FetchPinnedMessages {
                    conv_id,
                    to_fetch,
                    current_len,
                    rsp: tx,
                })) {
                    log::error!("failed to send warp command: {}", e);
                    continue;
                }

                match rx.await.expect("command canceled") {
                    Ok((m, has_more)) => {
                        newely_fetched_messages.set(Some((conv_id, m, has_more)));
                    }
                    Err(e) => {
                        log::error!("failed to fetch more message: {}", e);
                    }
                }
            }
        }
    });

    use_effect(cx, &chat.id, |id| {
        to_owned![ch, pinned_messages];
        async move {
            ch.send((id, 50, pinned_messages.read().len()));
        }
    });

    cx.render(rsx!(div {
        id: "pinned-messages",
        aria_label: "pinned-messages-label",
    }))
}
