use common::{state::State, STATIC_ARGS};
use dioxus::prelude::*;
use dioxus_router::use_router;

use crate::UPLINK_ROUTES;

#[allow(non_snake_case)]
pub fn LoadingLayout(cx: Scope) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let router = use_router(cx);
    if state.read().chats().initialized && state.read().friends().initialized {
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
