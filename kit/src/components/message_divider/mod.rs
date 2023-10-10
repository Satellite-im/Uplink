use std::time::Duration;

use dioxus::prelude::*;

#[derive(Eq, PartialEq, Props)]
pub struct Props {
    text: Option<String>,
    #[props(optional)]
    timestamp: Option<Duration>,
}

pub fn get_time_ago(cx: &Scope<Props>) -> String {
    let f = timeago::Formatter::new();
    cx.props.timestamp.map(|d| f.convert(d)).unwrap_or_default()
}

#[allow(non_snake_case)]
pub fn MessageDivider(cx: Scope<Props>) -> Element {
    let text = cx.props.text.clone().unwrap_or_default();
    let time_ago = get_time_ago(&cx);

    cx.render(rsx! (
        div {
            class: "message-divider noselect defaultcursor",
            hr {},
            p {
                class: "message-divider-text",
                span {
                    class: "badge-prefix",
                    "{text}"
                },
                span {
                    class: "badge-count",
                    "{time_ago}"
                }
            }
        }
    ))
}
