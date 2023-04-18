use common::{state::State, STATIC_ARGS};
use dioxus::prelude::*;
use dioxus_router::use_router;
use futures::channel::oneshot;

use crate::{utils::unzip_prism_langs, UPLINK_ROUTES};

#[allow(non_snake_case)]
pub fn LoadingLayout(cx: Scope) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let router = use_router(cx);

    let fut = use_future(cx, (), |_| async move {
        // unzip_prism_langs is blocking. run it on a separate thread and not on the async runtime.
        let (tx, rx) = oneshot::channel::<()>();
        std::thread::spawn(|| {
            unzip_prism_langs();
            let _ = tx.send(());
        });
        let _ = rx.await;
    });

    if fut.value().is_some()
        && state.read().chats().initialized
        && state.read().friends().initialized
    {
        router.replace_route(UPLINK_ROUTES.chat, None, None);
    }

    let img_path = STATIC_ARGS
        .extras_path
        .join("assets")
        .join("img")
        .join("uplink.gif");
    let img_path = img_path.to_string_lossy().to_string();
    cx.render(rsx!(img {
        style: "width: 100%",
        src: "{img_path}"
    }))
}
