use crate::elements::button::Button;
use crate::elements::Appearance;
use common::icons::outline::Shape as Icon;

use dioxus::prelude::*;

#[derive(Props)]
pub struct Props<'a> {
    open: bool,
    transparent: bool,
    children: Element<'a>,
    onclose: EventHandler<'a, ()>,
    class: Option<&'a str>,
}

#[allow(non_snake_case)]
pub fn Modal<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let transparent_class = cx.props.transparent.then(|| "transparent").unwrap_or("");

    cx.render(rsx!(cx.props.open.then(|| rsx!(
        div {
            class: "modal-wrap {transparent_class}",
            aria_label: "modal",
            onclick: move |_| cx.props.onclose.call(()),
            (!cx.props.transparent).then(|| rsx!(
                div {
                    class: "close-btn",
                    Button {
                        icon: Icon::XMark,
                        appearance: Appearance::Primary,
                        onpress: move |_| cx.props.onclose.call(()),
                    },
                }
            )),
            div {
                class: "modal {cx.props.class.unwrap_or_default()}",
                &cx.props.children
            }
        },
    ))))
}
