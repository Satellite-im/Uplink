use crate::elements::{button::Button, Appearance};
use common::icons::outline::Shape as Icon;
use dioxus::prelude::*;
use dioxus_desktop::use_window;

#[allow(non_snake_case)]
pub fn Topbar_Controls(cx: Scope) -> Element {
    let desktop = use_window(cx);
    cx.render(rsx!(
        div {
            class: "controls",
            Button {
                aria_label: "minimize-button".into(),
                icon: Icon::Minus,
                appearance: Appearance::Transparent,
                onpress: move |_| {
                    desktop.set_minimized(true);
                }
            },
            Button {
                aria_label: "square-button".into(),
                icon: Icon::Square2Stack,
                appearance: Appearance::Transparent,
                onpress: move |_| {
                    desktop.set_maximized(!desktop.is_maximized());
                }
            },
            Button {
                aria_label: "close-button".into(),
                icon: Icon::XMark,
                appearance: Appearance::Transparent,
                onpress: move |_| {
                    desktop.close();
                }
            },
        }
    ))
}
