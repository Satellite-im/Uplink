use common::icons::outline::Shape as Icon;
use common::icons::Icon as IconElement;
use dioxus::prelude::*;

#[derive(PartialEq, Eq, Props)]
pub struct Props {
    #[props(optional)]
    spinning: Option<bool>,
    #[props(optional)]
    large: Option<bool>,
}

pub fn is_large(cx: &Scope<Props>) -> bool {
    if let Some(f) = cx.props.large.as_ref() {
        return *f;
    }
    false
}

#[allow(non_snake_case)]
pub fn Loader(cx: Scope<Props>) -> Element {
    cx.render(rsx!(
    div {
        class: if is_large(&cx) { "loader large" } else { "loader" },
        div {
            class: "spin",
            aria_label: "loader",
            IconElement { icon: Icon::Loader }
        }
    }))
}
