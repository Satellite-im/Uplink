use dioxus::prelude::*;

const STYLE: &'static str = include_str!("./style.css");

#[derive(Props)]
pub struct Props<'a> {
    options: Vec<String>,
    #[props(optional)]
    onchange: Option<EventHandler<'a, String>>,
    #[props(optional)]
    onreturn: Option<EventHandler<'a, String>>,
}

pub fn emit(cx: &Scope<Props>, s: String) {
    match &cx.props.onchange {
        Some(f) => f.call(s),
        None => {},
    }
}

pub fn submit(cx: &Scope<Props>, s: String) {
    match &cx.props.onreturn {
        Some(f) => f.call(s),
        None => {},
    }
}

#[allow(non_snake_case)]
pub fn Input<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    cx.render(rsx! (
        style { "{STYLE}" }
        div {
            class: "input",
            input {
        
            }
        }
    ))
}
