use common::icons::outline::Shape as Icon;
use common::icons::Icon as IconElement;
use dioxus::prelude::*;

#[derive(PartialEq, Eq, Props)]
pub struct Props {
    #[props(optional)]
    spinning: Option<bool>,
}

#[allow(non_snake_case)]
pub fn Loader(cx: Scope<Props>) -> Element {
    cx.render(rsx!(
    div {
        class: "loader",
        div {
            class: "spin",
            IconElement { icon: Icon::Loader }
        }
    }))
}
