use common::icons::outline::Shape as Icon;
use common::icons::Icon as IconElement;

use dioxus::prelude::*;

#[derive(Props)]
pub struct Props<'a> {
    initial_value: f32,
    min: f32,
    max: f32,
    step: Option<f32>,
    onchange: EventHandler<'a, f32>,
    no_num: Option<bool>,
    icon_left: Option<Icon>,
    icon_right: Option<Icon>,
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
                step: "{step}",
                value: "{internal_state}",
                oninput: move |event| {
                    internal_state.set(event.value.parse().unwrap_or_default());
                    cx.props.onchange.call(event.value.parse().unwrap_or_default());
                },
            },
            cx.props.icon_right.is_some().then(|| rsx! {
                IconElement {
                    icon: cx.props.icon_right.unwrap_or(Icon::NoSymbol),
                    size: 16,
                }
            }),
            (!cx.props.no_num.unwrap_or_default()).then(||rsx!(
                p {
                    class: "range-value",
                    "{internal_state.get()}"
                }
            ))
        }
    ))
}
