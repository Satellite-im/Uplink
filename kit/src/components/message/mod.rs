use std::fmt;

use dioxus::prelude::*;

#[derive(Eq, PartialEq, Clone, Copy)]
pub enum Order {
    First,
    Middle,
    Last,
}

impl fmt::Display for Order {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Order::First => write!(f, "message-first"),
            Order::Middle => write!(f, "message-middle"),
            Order::Last => write!(f, "message-last"),
        }
    }
}

#[derive(Props)]
pub struct Props<'a> {
    // An optional field that, if set to true, will add a CSS class of "loading" to the div element.
    #[props(optional)]
    loading: Option<bool>,

    // An optional field that, if set, will be used as the content of a nested div element with a class of "content".
    #[props(optional)]
    with_content: Option<Element<'a>>,

    // An optional field that, if set, will be used as the text content of a nested p element with a class of "text".
    #[props(optional)]
    with_text: Option<String>,

    // An optional field that, if set to true, will add a CSS class of "remote" to the div element.
    #[props(optional)]
    remote: Option<bool>,

    // An optional field that, if set, will be used to determine the ordering of the div element relative to other Message elements.
    // The value will be converted to a string using the Order enum's fmt::Display implementation and used as a CSS class of the div element.
    // If not set, the default value of Order::Last will be used.
    #[props(optional)]
    order: Option<Order>,
}

#[allow(non_snake_case)]
pub fn Message<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let text = cx.props.with_text.clone().unwrap_or_default();
    let loading = cx.props.loading.unwrap_or_default();
    let remote = cx.props.remote.unwrap_or_default();
    let order = cx.props.order.unwrap_or(Order::Last);

    cx.render(rsx! (
        div {
            class: {
                format_args!(
                    "message {} {} {}",
                    if loading {
                        "loading"
                    } else { "" },
                    if remote {
                        "remote"
                    } else { "" },
                    if cx.props.order.is_some() {
                        order.to_string()
                    } else { "".into() }
                )
            },
            (cx.props.with_content.is_some()).then(|| rsx! (
                    div {
                    class: "content",
                    &cx.props.with_content,
                },
            )),
            (cx.props.with_text.is_some()).then(|| rsx! (
                p {
                    class: "text",
                    "{text}"
                }
            ))
        }
    ))
}
