use common::icons::outline::Shape;
use dioxus::prelude::*;
use tracing::log;

use crate::elements::button::Button;

#[derive(Clone, PartialEq, Eq)]
pub enum ButtonsFormat {
    PlusAndMinus,
    Arrows,
}

#[derive(Props)]
pub struct Props<T: 'static> {
    values: Vec<T>,
    initial_index: usize,
    // #[props(optional)]
    // buttons_format: Option<ButtonsFormat>,
    onset: EventHandler<T>,
}

impl<T> Clone for Props<T> {
    fn clone(&self) -> Self {
        Self {
            values: self.values.clone(),
            initial_index: self.initial_index.clone(),
            // buttons_format: self.buttons_format.clone(),
            onset: self.onset.clone(),
        }
    }
}

#[allow(non_snake_case)]
pub fn SlideSelector<T>(props: Props<T>) -> Element
where
    T: std::fmt::Display + Clone,
{
    let index = use_signal(|| props.initial_index);
    if *index.read() != props.initial_index {
        index.set(props.initial_index);
    }
    // let buttons_format = props
    // .buttons_format
    // .clone()
    // .unwrap_or(ButtonsFormat::Arrows);

    let buttons_format = ButtonsFormat::Arrows;

    let converted_display = match props.values.get(*index.current()) {
        Some(x) => x.to_string(),
        None => {
            log::error!("failed to get value in SlideSelector");
            "?".into()
        }
    };

    rsx!(div {
        class: "slide-selector",
        aria_label: "slide-selector",
        Button {
            aria_label: "slide-selector-minus".into(),
            icon: if buttons_format == ButtonsFormat::PlusAndMinus {Shape::Minus} else {Shape::ArrowLeft},
            disabled: *index.get() == 0,
            onpress: move |_| {
                if *index.get() == 0 {
                    return;
                }
                let new_val = index.get() - 1;
                index.set(new_val);
                if let Some(x) = props.values.get(new_val) {
                     props.onset.call(x.clone());
                }
            },
        },
        span {
            aria_label: "slide-selector-value",
            class: "slide-selector__value",
            "{converted_display}",
        },
        Button {
            aria_label: "slide-selector-plus".into(),
            icon: if buttons_format == ButtonsFormat::PlusAndMinus {Shape::Plus} else {Shape::ArrowRight},
            disabled: *index.read() >= (props.values.len() - 1),
            onpress: move |_| {
                if *index.read() >= (props.values.len() - 1) {
                    return;
                }
                let new_val = index.read() + 1;
                index.set(new_val);
                if let Some(x) = props.values.get(new_val) {
                    props.onset.call(x.clone());
               }
            },
        },
    })
}
