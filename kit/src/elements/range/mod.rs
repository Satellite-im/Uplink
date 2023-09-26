use common::icons::outline::Shape as Icon;
use common::icons::Icon as IconElement;

use dioxus::prelude::*;

#[derive(Props)]
pub struct Props<'a> {
    initial_value: f64,
    min: f64,
    max: f64,
    onchange: EventHandler<'a, f64>,
    step: Option<f64>,
    icon_left: Option<Icon>,
    icon_right: Option<Icon>,
}

#[allow(non_snake_case)]
pub fn Range<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let internal_state: &UseState<f64> = use_state(cx, || cx.props.initial_value);
    let step = cx.props.step.unwrap_or(1.0);

    cx.render(rsx!(
        div {
            class: "range",
            cx.props.icon_left.is_some().then(|| rsx! {
                IconElement {
                    icon: cx.props.icon_left.unwrap_or(Icon::NoSymbol),
                    size: 16,
                }
            }),
            input {
                "type": "range",
                min: "{cx.props.min}",
                max: "{cx.props.max}",
                step: format_args!("{}", step),
                onchange: move |event| {
                    internal_state.set(event.value.parse().unwrap_or_default());
                    cx.props.onchange.call(event.value.parse().unwrap_or_default());
                }
            },
            cx.props.icon_right.is_some().then(|| rsx! {
                IconElement {
                    icon: cx.props.icon_right.unwrap_or(Icon::NoSymbol),
                    size: 16,
                }
            }),
            p {
                class: "range-value",
                "{internal_state.get()}"
            }
        }
    ))
}
