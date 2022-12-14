use dioxus::prelude::*;
use ui_kit::{
    elements::{button::Button, Appearance},
    icons::Icon,
};

#[allow(non_snake_case)]
pub fn Welcome(cx: Scope) -> Element {
    let router = use_router(&cx).clone();

    cx.render(rsx! {
        div {
            id: "welcome",
            img {
                src: "extra/assets/img/uplink_muted.png"
            },
            p {
                class: "muted",
                "No active chats, wanna make one?"
            },
            Button {
                icon: Icon::Plus,
                text: "Add Someone".into(),
                appearance: Appearance::Secondary,
                onpress: move |_| {
                    router.replace_route("/friends", None, None);
                }
            },
        }
    })
}
