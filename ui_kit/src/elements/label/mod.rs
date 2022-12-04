use dioxus::prelude::*;


const STYLE: &'static str = include_str!("./style.css");

#[derive(PartialEq, Props)]
pub struct Props {
    text: String
}

#[allow(non_snake_case)]
pub fn Label(cx: Scope<Props>) -> Element {
    cx.render(rsx!(
        style {
            "{STYLE}"
        }
        label {
            "{cx.props.text}"
        }
    ))
}
