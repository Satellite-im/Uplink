use dioxus::prelude::*;

// Remember: owned props must implement PartialEq!
#[derive(Props)]
pub struct Props<'a> {
    #[props(optional)]
    _loading: Option<bool>,
    _min: i32,
    _max: i32,
    #[props(optional)]
    default_value: Option<i32>,
    #[props(optional)]
    _onflipped: Option<EventHandler<'a, i32>>,
}

pub fn get_default(cx: &Scope<Props>) -> i32 {
    cx.props.default_value.unwrap_or_default()
}

#[allow(non_snake_case)]
pub fn Slider<'a>(cx: Scope<'a, Props>) -> Element<'a> {
    let _slider_value = use_state(cx, || get_default(&cx));
    // TODO: Pending dioxus update for eval returning values
    cx.render(rsx! {
        div {
            class: "slider",
        }
    })
}
