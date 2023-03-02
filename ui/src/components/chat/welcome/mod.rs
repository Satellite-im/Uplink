use dioxus::prelude::*;

use crate::UPLINK_ROUTES;
use common::icons::outline::Shape as Icon;
use common::language::get_local_text;
use dioxus_router::use_router;
use kit::elements::{button::Button, Appearance};

#[allow(non_snake_case)]
pub fn Welcome(cx: Scope) -> Element {
    let router = use_router(cx).clone();
    let cta_text = get_local_text("friends.cta-text");

    cx.render(rsx! {
        div {
            id: "welcome",
            aria_label: "welcome-screen",
            img {
                class: "image",
                src: "./ui/extra/images/mascot/better_with_friends.png"
            },
            p {
                class: "muted",
                "{cta_text}"
            },
            Button {
                icon: Icon::Plus,
                aria_label: "add-friends-button".into(),
                text: get_local_text("friends.add"),
                appearance: Appearance::Secondary,
                onpress: move |_| {
                    router.replace_route(UPLINK_ROUTES.friends, None, None);
                }
            },
        }
    })
}
