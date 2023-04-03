use common::icons::outline::Shape;
use dioxus::prelude::*;

use crate::elements::{button::Button, Appearance};

#[derive(Props)]
pub struct Props<'a> {
    values: Vec<&'static str>,
    disp: String,
    idx: usize,
    onset: EventHandler<'a, usize>,
}

#[allow(non_snake_case)]
pub fn SlideSelector<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    cx.render(rsx!(div {
        class: "slide-selector",
        aria_label: "slide-selector",
        Button {
            icon: Shape::Minus,
            appearance: Appearance::Primary,
            onpress: move |_| {
                if cx.props.idx == 0 {
                    return;
                }

                cx.props.onset.call(cx.props.idx - 1);
            },
        },
        span {
            class: "slide-selector__value",
            "{cx.props.disp}",
        },
        Button {
            icon: Shape::Plus
            appearance: Appearance::Primary,
            onpress: move |_| {
                if cx.props.idx >= cx.props.values.len() {
                    return;
                }

                cx.props.onset.call(cx.props.idx + 1);
            },
        },
    }))
}
