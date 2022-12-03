use dioxus::prelude::*;

const STYLE: &'static str = include_str!("./style.css");

#[derive(Props)]
pub struct Props<'a> {
    options: Vec<String>,
    #[props(optional)]
    onselect: Option<EventHandler<'a, String>>,
}

/// Tells the parent the button was interacted with.
pub fn emit(cx: &Scope<Props>, s: String) {
    match &cx.props.onselect {
        Some(f) => f.call(s),
        None => {},
    }
}

#[allow(non_snake_case)]
pub fn Select<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let iter = IntoIterator::into_iter(cx.props.options.clone());
    cx.render(rsx!(
        style { "{STYLE}" }
        div { 
            class: "select",
            select {
                onchange: move |e| emit(&cx, e.value.clone()),
                iter.map(|val| rsx! (
                    option { label: "{val}", value: "{val}" }
                ))
            }
        }
    ))
}
