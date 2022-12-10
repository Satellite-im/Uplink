use dioxus::prelude::*;

const STYLE: &str = include_str!("./style.css");

#[derive(Props)]
pub struct Props<'a> {
    #[props(optional)]
    with_search: Option<Element<'a>>,
    #[props(optional)]
    with_nav: Option<Element<'a>>,
    #[props(optional)]
    children: Option<Element<'a>>,
}

#[allow(non_snake_case)]
pub fn Sidebar<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    cx.render(rsx!(
        style {
            "{STYLE}"
        },
        div {
            class: "sidebar",
            div {
                class: "search",
                &cx.props.with_search
            },
            div {
                class: "children",
                &cx.props.children
            },
            &cx.props.with_nav,
        }
    ))
}
