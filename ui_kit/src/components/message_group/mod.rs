use std::time::Duration;

use dioxus::prelude::*;

#[derive(Props)]
pub struct Props<'a> {
    children: Element<'a>,
    user_image: Element<'a>,
    #[props(optional)]
    remote: Option<bool>,
    #[props(optional)]
    timestamp: Option<Duration>,
    #[props(optional)]
    with_sender: Option<String>
}

pub fn get_time_ago(cx: &Scope<Props>) -> String {
    let f = timeago::Formatter::new();
    cx.props.timestamp.map(|d|f.convert(d)).unwrap_or_default()
}

#[allow(non_snake_case)]
pub fn MessageGroup<'a>(cx: Scope<'a,Props<'a>>) -> Element<'a> {
    let remote = cx.props.remote.unwrap_or_default();
    let sender = cx.props.with_sender.clone().unwrap_or_default();
    let time_ago = get_time_ago(&cx);
    
    cx.render(rsx! (
        div {
            class: "message-group-wrap",
            remote.then(|| rsx!(
                &cx.props.user_image
            ))
            div {
                class: {
                    format_args!("message-group {}", if remote { "remote" } else { "" })
                },
                &cx.props.children,
                p {
                    class: "time-ago noselect defaultcursor",
                    "{time_ago}"
                }
                (!sender.is_empty()).then(|| rsx! (
                    p {
                        class: "sender",
                        "{sender}"
                    }
                )),
            }
            (!remote).then(|| rsx!(
                &cx.props.user_image
            ))
        }
    ))
}