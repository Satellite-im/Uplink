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

pub fn is_large(props: Props) -> bool {
    if let Some(f) = props.large.as_ref() {
        return *f;
    }
    false
}

#[allow(non_snake_case)]
pub fn Loader(props: Props) -> Element {
    rsx!(
    div {
        class: if is_large(&cx) { "loader large" } else { "loader" },
        div {
            class: "spin",
            IconElement { icon: Icon::Loader }
        }
    })
}
