use common::icons::outline::Shape;
use dioxus::prelude::*;
use warp::logging::tracing::log;

use crate::elements::{button::Button, Appearance};

#[derive(Clone, PartialEq, Eq)]
pub enum ButtonsFormat {
    PlusAndMinus,
    Arrows,
}

#[derive(Props)]
pub struct Props<'a, T> {
    values: Vec<T>,
    inital_index: usize,
    #[props(default)]
    buttons_format: Option<ButtonsFormat>,
    onset: EventHandler<'a, T>,
}

#[allow(non_snake_case)]
pub fn SlideSelector<'a, T>(cx: Scope<'a, Props<'a, T>>) -> Element<'a>
where
    T: std::fmt::Display + Clone,
{
    let index = use_state(&cx, || cx.props.inital_index);
    let buttons_format = cx
        .props
        .buttons_format
        .clone()
        .unwrap_or(ButtonsFormat::Arrows);

    let converted_display = match cx.props.values.get(*index.current()) {
        Some(x) => x.to_string(),
        None => {
            log::error!("failed to get value in SlideSelector");
            "?".into()
        }
    };

    cx.render(rsx!(div {
        class: "slide-selector",
        aria_label: "slide-selector",
        Button {
            icon: if buttons_format == ButtonsFormat::PlusAndMinus {Shape::Minus} else {Shape::ArrowLeft},
            appearance: Appearance::Primary,
            disabled: if *index.get() == 0 {true} else {false},
            onpress: move |_| {
                if *index.get() == 0 {
                    return;
                }
                index.set(index.get() - 1);
                if let Some(x) = cx.props.values.get(*index.get()) {
                     cx.props.onset.call(x.clone());
                }
            },
        },
        span {
            class: "slide-selector__value",
            "{converted_display}",
        },
        Button {
            icon: if buttons_format == ButtonsFormat::PlusAndMinus {Shape::Plus} else {Shape::ArrowRight},
            appearance: Appearance::Primary,
            disabled: if *index.get() >= (cx.props.values.len() - 1)  {true} else {false},
            onpress: move |_| {
                if *index.get() >= (cx.props.values.len() - 1) {
                    return;
                }
                index.set(index.get() + 1);
                if let Some(x) = cx.props.values.get(*index.get()) {
                    cx.props.onset.call(x.clone());
               }
            },
        },
    }))
}
