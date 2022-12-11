use std::fmt;

use dioxus::prelude::*;

#[derive(Eq, PartialEq, Clone, Copy)]
pub enum Order {
    First,
    Middle,
    Last
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
    #[props(optional)]
    loading: Option<bool>,
    #[props(optional)]
    with_content: Option<Element<'a>>,
    #[props(optional)]
    with_text: Option<String>,
    #[props(optional)]
    remote: Option<bool>,
    #[props(optional)]
    order: Option<Order>
}

#[allow(non_snake_case)]
pub fn Message<'a>(cx: Scope<'a,Props<'a>>) -> Element<'a> {
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