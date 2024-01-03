use dioxus::prelude::*;

use crate::elements::{button::Button, Appearance};
use common::icons;

#[derive(Props)]
pub struct Props<'a> {
    with_back_button: Option<bool>,
    onback: Option<EventHandler<'a>>,
    with_nav: Option<Element<'a>>,
    navbar_visible: bool,
    top_children: Option<Element<'a>>,
    children: Option<Element<'a>>,
}

/// If enabled, it will render the bool
pub fn show_back_button(cx: &Scope<Props>) -> bool {
    cx.props.with_back_button.unwrap_or(false)
}

/// Emit the back button event
pub fn emit(cx: &Scope<Props>) {
    match &cx.props.onback {
        Some(f) => f.call(()),
        None => {}
    }
}

#[allow(non_snake_case)]
pub fn Slimbar<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    cx.render(rsx!(div {
        class: "slimbar",
        aria_label: "slimbar",
        (show_back_button(&cx)).then(|| rsx!(
            div {
                class: "slimbar-back",
                Button {
                    aria_label: "back-button".into(),
                    icon: icons::outline::Shape::Sidebar,
                    onpress: move |_| emit(&cx),
                    appearance: Appearance::Secondary
                }
            }
        )),
        div {
            class: "slimbar-scroll",
            div {
                class: "slimbar-top",
                cx.props.top_children.clone(),
            }
            div {
                class: "slimbar-inner",
                cx.props.children.clone(),
            }
        }

        cx.props.navbar_visible.then(|| rsx!(div {
            class: "nav-vertical-wrapper",
            cx.props.with_nav.clone(),
        })),
    }))
}
