use dioxus::prelude::*;

const STYLE: &'static str = include_str!("./style.css");

// Remember: owned props must implement PartialEq!
#[derive(Props)]
pub struct Props<'a> {
    min: i32,
    max: i32,
    #[props(optional)]
    default_value: Option<i32>
}

#[allow(non_snake_case)]
pub fn Slider<'a>(cx: Scope<'a, Props>) -> Element<'a> {
    let slider_value = default_state(&cx);

    cx.render(rsx! {
        style { "{STYLE}" },
        label {
            class: "switch",
            input {
                "type": "checkbox",
                checked: "{checked_state}",
                oninput: move |e| emit(&cx, if e.data.value == "true" { true } else { false })
            },
            span { class: "slider" }
        }
    })
}
