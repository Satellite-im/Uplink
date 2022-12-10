use dioxus::prelude::*;

const STYLE: &'static str = include_str!("./style.css");

// Remember: owned props must implement PartialEq!
#[derive(Props)]
pub struct Props<'a> {
    #[props(optional)]
    loading: Option<bool>,
    min: i32,
    max: i32,
    #[props(optional)]
    default_value: Option<i32>,
    #[props(optional)]
    onflipped: Option<EventHandler<'a, i32>>,
}

pub fn get_default(cx: &Scope<Props>) -> i32 {
    match &cx.props.default_value {
        Some(v) => v.clone(),
        None => 0,
    }
}

#[allow(non_snake_case)]
pub fn Slider<'a>(cx: Scope<'a, Props>) -> Element<'a> {
    let slider_value = use_state(&cx, || get_default(&cx));

    cx.render(rsx! {
        style { "{STYLE}" },
        div {
            class: "slider",
        }
    })
}
