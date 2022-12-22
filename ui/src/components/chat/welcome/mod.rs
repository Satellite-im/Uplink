use dioxus::prelude::*;

use dioxus_router::use_router;
use fluent_templates::Loader;
use kit::{
    elements::{button::Button, Appearance},
    icons::Icon,
};

use crate::utils::language::get_local_text;

#[allow(non_snake_case)]
pub fn Welcome(cx: Scope) -> Element {
    let router = use_router(&cx).clone();
    let cta_text = get_local_text("friends.add");
    cx.render(rsx! {
        div {
            id: "welcome",
            img {
                src: "ui/extra/assets/img/uplink_muted.png"
            },
            p {
                class: "muted",
                "{cta_text}"
            },
            Button {
                icon: Icon::Plus,
                text: get_local_text("friends.add"),
                appearance: Appearance::Secondary,
                onpress: move |_| {
                    router.replace_route("/friends", None, None);
                }
            },
        }
    })
}
