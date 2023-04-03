use common::icons::outline::Shape;
use dioxus::prelude::*;

use crate::elements::{button::Button, Appearance};

#[derive(Props)]
pub struct Props<'a> {
    current: usize,
    values: Vec<&'static str>,
    onset: EventHandler<'a, &'static str>,
}

fn get_by_index(index: usize, values: &[&'static str]) -> &'static str {
    values.get(index).unwrap_or(&"")
}

#[allow(non_snake_case)]
pub fn SlideSelector<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let current = use_state(cx, || cx.props.current);
    let current_value = use_state(cx, || get_by_index(*current.get(), &cx.props.values));

    let state = use_shared_state::<common::state::State>(cx)?;

    cx.render(rsx!(div {
        class: "slide-selector",
        aria_label: "slide-selector",
        Button {
            icon: Shape::Minus,
            appearance: Appearance::Primary,
            onpress: move |_| {
                if *current.get() == 0 {
                    return;
                }
                current.set(current.get() - 1);
                current_value.set(get_by_index(*current.get(), &cx.props.values));
                cx.props.onset.call(*current_value.get());
            },
        },
        span {
            class: "slide-selector__value",
            "{state.read().ui.font_scale}x",
        },
        Button {
            icon: Shape::Plus
            appearance: Appearance::Primary,
            onpress: move |_| {
                if *current.get() == cx.props.values.len() - 1 {
                    return;
                }
                current.set(current.get() + 1);
                current_value.set(get_by_index(*current.get(), &cx.props.values));
                cx.props.onset.call(*current_value.get());
            },
        },
    }))
}
