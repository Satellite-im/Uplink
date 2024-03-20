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
pub struct Props<T: 'static + std::clone::Clone> {
    values: Vec<T>,
    initial_index: usize,
    #[props(optional)]
    buttons_format: Option<ButtonsFormat>,
    onset: EventHandler<T>,
}

impl<T: std::clone::Clone> Clone for Props<T> {
    fn clone(&self) -> Self {
        Self {
            values: self.values,
            initial_index: self.initial_index.clone(),
            buttons_format: self.buttons_format.clone(),
            onset: self.onset.clone(),
        }
    }
}

impl<T: std::clone::Clone> PartialEq for Props<T> {
    fn eq(&self, other: &Self) -> bool {
        self.initial_index == other.initial_index && self.buttons_format == other.buttons_format
    }
}

#[allow(non_snake_case)]
pub fn SlideSelector<T>(props: Props<T>) -> Element
where
    T: std::fmt::Display + Clone,
{
    let mut index = use_signal(|| props.initial_index);
    if *index.read() != props.initial_index {
        index.set(props.initial_index);
    }
    let buttons_format = props
        .buttons_format
        .clone()
        .unwrap_or(ButtonsFormat::Arrows);

    let converted_display = match props.values.get(*index.read()) {
        Some(x) => x.to_string(),
        None => {
            log::error!("failed to get value in SlideSelector");
            "?".into()
        }
    };

    rsx!(
            div { class: "slide-selector", aria_label: "slide-selector",
                Button {
                    aria_label: "slide-selector-minus".to_string(),
                    icon: if buttons_format == ButtonsFormat::PlusAndMinus {
        Shape::Minus
    } else {
        Shape::ArrowLeft
    },
                    disabled: *index.read() == 0,
                    onpress: move |_| {
                        if *index.read() == 0 {
                            return;
                        }
                        let new_val = *index.read() - 1;
                        index.set(new_val);
                        if let Some(x) = props.values.get(new_val) {
                            props.onset.call(x.clone());
                        }
                    }
                }
                span { aria_label: "slide-selector-value", class: "slide-selector__value", "{converted_display}" }
                Button {
                    aria_label: "slide-selector-plus".to_string(),
                    icon: if buttons_format == ButtonsFormat::PlusAndMinus {
        Shape::Plus
    } else {
        Shape::ArrowRight
    },
                    disabled: *index.read() >= (props.values.len() - 1),
                    onpress: move |_| {
                        if *index.read() >= (props.values.len() - 1) {
                            return;
                        }
                        let new_val = *index.read() + 1;
                        index.set(new_val);
                        if let Some(x) = props.values.get(new_val) {
                            props.onset.call(x.clone());
                        }
                    }
                }
            }
        )
}
