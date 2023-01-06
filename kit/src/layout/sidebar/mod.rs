use dioxus::prelude::*;

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
        div {
            class: "sidebar",
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
        }
    ))
}
