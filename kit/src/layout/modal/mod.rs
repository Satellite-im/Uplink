use crate::elements::button::Button;
use crate::elements::label::Label;
use crate::elements::Appearance;
use common::icons::outline::Shape as Icon;

use dioxus::prelude::*;

#[derive(Props)]
pub struct Props<'a> {
    open: bool,
    with_title: Option<String>,
    transparent: bool,
    #[props(optional)]
    dont_pad: Option<bool>,
    children: Element<'a>,
    onclose: EventHandler<'a, ()>,
    class: Option<&'a str>,
}

#[allow(non_snake_case)]
pub fn Modal<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let transparent_class = if cx.props.transparent {
        "transparent"
    } else {
        ""
    };
    let no_padding_class = if cx.props.dont_pad.unwrap_or_default() {
        "no-padding"
    } else {
        ""
    };
    let title = cx.props.with_title.clone().unwrap_or_default();

    cx.render(rsx!(cx.props.open.then(|| rsx!(
        div {
            class: "modal-wrap {transparent_class} {no_padding_class}",
            aria_label: "modal",
            onclick: move |_| cx.props.onclose.call(()),
            div {
                class: "modal {cx.props.class.unwrap_or_default()}",
                (!cx.props.transparent).then(|| rsx!(
                    div {
                        class: "close-btn",
                        Button {
                            icon: Icon::XMark,
                            appearance: Appearance::Secondary,
                            onpress: move |_| cx.props.onclose.call(()),
                        },
                    }
                )),
                cx.props.with_title.is_some().then(|| rsx!(
                    Label {
                        text: title,
                    }
                )),
                &cx.props.children
            }
        },
    ))))
}
