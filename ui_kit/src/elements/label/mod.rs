use dioxus::prelude::*;


const STYLE: &str = include_str!("./style.css");

#[derive(PartialEq, Eq, Props)]
pub struct Props {
    #[props(optional)]
    loading: Option<bool>,
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
