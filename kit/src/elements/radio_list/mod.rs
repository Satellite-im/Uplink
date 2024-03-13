use crate::elements::button::Button;
use crate::elements::Appearance;
use common::icons::outline::Shape as Icon;
use dioxus::prelude::*;

#[derive(Props)]
pub struct Props<'a> {
    initial_value: String,
    values: Vec<String>,
    onchange: EventHandler<String>,
}

#[allow(non_snake_case)]
pub fn RadioList<'a>(props: Props<'a>) -> Element {
    let internal_state = use_state(cx, || props.initial_value.clone());

    rsx!(
        div {
            class: "radio-list",
            for option in &props.values {
                Button {
                    icon: if internal_state.get() == option { Icon::RadioSelected } else { Icon::Radio },
                    appearance: if internal_state.get() == option { Appearance::Primary } else { Appearance::Secondary },
                    text: option.clone(),
                    aria_label: format!("radio-option-{}", option),
                    onpress: move |_| {
                        internal_state.set(option.clone());
                        props.onchange.call(option.clone());
                    },
                }
            }
        }
    )
}
