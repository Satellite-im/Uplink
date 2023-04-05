use common::icons::outline::Shape;
use dioxus::prelude::*;

use crate::elements::{button::Button, Appearance};

#[derive(Props)]
pub struct Props<'a> {
    values: Vec<f64>,
    inital_index: usize,
    onset: EventHandler<'a, usize>,
}

#[allow(non_snake_case)]
pub fn SlideSelector<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let to_display = use_state(&cx, || cx.props.values.get(cx.props.inital_index));
    let index = use_state(&cx, || cx.props.inital_index);

    let converted_display = to_display.get().unwrap_or(&1.0);

    cx.render(rsx!(div {
        class: "slide-selector",
        aria_label: "slide-selector",
        Button {
            icon: Shape::Minus,
            appearance: Appearance::Primary,
            onpress: move |_| {
                if *index.get() == 0 {
                    return;
                }
                index.set(index.get() - 1);
                let selected_value = cx.props.values.get(*index.get());
                cx.props.onset.call(selected_value);
                to_display.set(selected_value);
            },
        },
        span {
            class: "slide-selector__value",
            "{converted_display.to_string()}",
        },
        Button {
            icon: Shape::Plus
            appearance: Appearance::Primary,
            onpress: move |_| {
                if *index.get() >= cx.props.values.len() {
                    return;
                }
                index.set(index.get() + 1);
                let selected_value = cx.props.values.get(*index.get());

                cx.props.onset.call(selected_value);
                to_display.set(selected_value);
            },
        },
    }))
}
