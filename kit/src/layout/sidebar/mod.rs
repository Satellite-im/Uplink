use dioxus::prelude::*;

#[derive(Props)]
pub struct Props<'a> {
    #[props(optional)]
    with_search: Option<Element<'a>>,
    #[props(optional)]
    with_nav: Option<Element<'a>>,
    #[props(optional)]
    hidden: Option<bool>,
    #[props(optional)]
    children: Option<Element<'a>>,
}

const SCRIPT: &str = include_str!("./script.js");

#[allow(non_snake_case)]
pub fn Sidebar<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let hidden = cx.props.hidden.unwrap_or(false);

    cx.render(rsx!(
        div {
            class: {
                format_args!("sidebar resize-horiz-right {}", if hidden { "hidden" } else { "" })
            },
            aria_label: "sidebar",
            div {
                class: "search",
                aria_label: "sidebar-search",
                cx.props.with_search.as_ref()
            },
            div {
                class: "children",
                aria_label: "sidebar-children",
                cx.props.children.as_ref()
            },
            cx.props.with_nav.as_ref(),
        },
        script { SCRIPT }
    ))
}
