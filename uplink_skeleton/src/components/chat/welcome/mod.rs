use dioxus::prelude::*;
use fluent_templates::Loader;
use ui_kit::{
    elements::{button::Button, Appearance},
    icons::Icon,
};

use crate::{LOCALES, US_ENGLISH};

#[allow(non_snake_case)]
pub fn Welcome(cx: Scope) -> Element {
    let router = use_router(&cx).clone();
    let add_text = LOCALES
        .lookup(&US_ENGLISH, "friends.add")
        .unwrap_or_default();

    let cta_text = LOCALES
        .lookup(&US_ENGLISH, "friends.add")
        .unwrap_or_default();

    cx.render(rsx! {
        div {
            id: "welcome",
            img {
                src: "../../../../extra/assets/img/uplink_muted.png"
            },
            p {
                class: "muted",
                "{cta_text}"
            },
            Button {
                icon: Icon::Plus,
                text: add_text,
                appearance: Appearance::Secondary,
                onpress: move |_| {
                    router.replace_route("/friends", None, None);
                }
            },
        }
    })
}
