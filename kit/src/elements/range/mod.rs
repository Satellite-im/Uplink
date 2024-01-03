use common::icons::outline::Shape as Icon;
use common::icons::Icon as IconElement;

use dioxus::prelude::*;

use crate::elements::button::Button;
use crate::elements::Appearance;

#[derive(Props)]
pub struct Props<'a> {
    initial_value: f32,
    min: f32,
    max: f32,
    step: Option<f32>,
    with_buttons: Option<bool>,
    onchange: EventHandler<'a, f32>,
    no_num: Option<bool>,
    icon_left: Option<Icon>,
    icon_right: Option<Icon>,
    aria_label: Option<String>,
    disabled: Option<bool>,
}

#[allow(non_snake_case)]
pub fn Range<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let internal_state = use_state(cx, || cx.props.initial_value);
    use_effect(cx, &cx.props.initial_value, |val| {
        to_owned![internal_state];
        async move {
            internal_state.set(val);
        }
    });
    let step = cx.props.step.unwrap_or(1_f32);
    let aria_label = cx.props.aria_label.clone().unwrap_or_default();

    let with_buttons = cx.props.with_buttons.unwrap_or_default();

    cx.render(rsx!(
        div {
            class: "range",
            aria_label: "{aria_label}",
            if with_buttons {
                rsx!(Button {
                    icon: Icon::Minus,
                    appearance: Appearance::PrimaryAlternative,
                    disabled: cx.props.disabled.unwrap_or_default(),
                    aria_label: "decrease_range_value_button".into(),
                    onpress: move |_| {
                        if internal_state.get() > &cx.props.min {
                            let value: f32 = internal_state.get() - step;
                            let rounded_value = (value * 10.0).round() / 10.0;
                            internal_state.set(rounded_value);
                            cx.props.onchange.call(*internal_state.get());
                        }
                    }
                })
            } else {
                rsx! {
                    cx.props.icon_left.is_some().then(|| rsx! {
                        IconElement {
                            icon: cx.props.icon_left.unwrap_or(Icon::NoSymbol),
                            size: 16,
                        }
                    }),
                }
            }
            input {
                "type": "range",
                min: "{cx.props.min}",
                max: "{cx.props.max}",
                aria_label: "range-input",
                step: "{step}",
                value: "{internal_state}",
                disabled: cx.props.disabled.unwrap_or_default(),
                oninput: move |event| {
                    internal_state.set(event.value.parse().unwrap_or_default());
                    cx.props.onchange.call(event.value.parse().unwrap_or_default());
                },
            },
            if with_buttons {
                rsx!(Button {
                    icon: Icon::Plus,
                    appearance: Appearance::PrimaryAlternative,
                    aria_label: "increase_range_value_button".into(),
                    onpress: move |_| {
                        if internal_state.get() < &cx.props.max {
                            let value: f32 = internal_state.get() + step;
                            let rounded_value = (value * 10.0).round() / 10.0;
                            internal_state.set(rounded_value);
                            cx.props.onchange.call(*internal_state.get());
                        }
                    }
                })
            } else {
                rsx! {
                    cx.props.icon_right.is_some().then(|| rsx! {
                        IconElement {
                            icon: cx.props.icon_right.unwrap_or(Icon::NoSymbol),
                            size: 16,
                        }
                    })
                }
            }
            (!cx.props.no_num.unwrap_or_default()).then(||rsx!(
                p {
                    aria_label: "range-value",
                    class: "range-value",
                    "{internal_state.get()}"
                }
            ))
        }
    ))
}
