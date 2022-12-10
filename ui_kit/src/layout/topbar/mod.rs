use dioxus::prelude::*;

use crate::{icons::Icon, elements::{Appearance, button::Button}};

const STYLE: &'static str = include_str!("./style.css");

#[derive(Props)]
pub struct Props<'a> {
    #[props(optional)]
    with_back_button: Option<bool>,
    #[props(optional)]
    onback: Option<EventHandler<'a>>,
    #[props(optional)]
    controls: Option<Element<'a>>,
    #[props(optional)]
    children: Option<Element<'a>>,
}

/// If enabled, it will render the bool
pub fn show_back_button(cx: &Scope<Props>) -> bool {
    match cx.props.with_back_button {
        Some(b) => b,
        None => false,
    }
}

/// Emit the back button event
pub fn emit(cx: &Scope<Props>) {
    match &cx.props.onback {
        Some(f) => f.call(()),
        None => {},
    }
}

#[allow(non_snake_case)]
pub fn Topbar<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    cx.render(
        rsx!(
            style { "{STYLE}" }
            div {
                class: "topbar",
                (show_back_button(&cx)).then(|| rsx!(
                    Button {
                        icon: Icon::ChevronLeft,
                        onpress: move |_| emit(&cx),
                        appearance: Appearance::Secondary
                    }
                )),
                div {
                    class: "children",
                    &cx.props.children
                },
                div {
                    class: "controls",
                    &cx.props.controls
                }
            }
        )
    )
}