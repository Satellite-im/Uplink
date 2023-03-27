use derive_more::Display;
use dioxus::prelude::*;

#[derive(Eq, PartialEq, Clone, Copy, Display)]
pub enum Order {
    #[display(fmt = "message-first")]
    First,

    #[display(fmt = "message-middle")]
    Middle,

    #[display(fmt = "message-last")]
    Last,
}

#[derive(Props)]
pub struct Props<'a> {
    #[props(optional)]
    user_image: Option<Element<'a>>,
    #[props(optional)]
    loading: Option<bool>,
    #[props(optional)]
    with_text: Option<String>,
    #[props(optional)]
    remote: Option<bool>,
    #[props(optional)]
    remote_message: Option<bool>,
    #[props(optional)]
    with_prefix: Option<String>,
}

#[allow(non_snake_case)]
pub fn MessageReply<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let text = cx.props.with_text.clone().unwrap_or_default();
    let prefix = cx.props.with_prefix.clone().unwrap_or_default();
    let loading = cx.props.loading.unwrap_or_default();
    let remote = cx.props.remote.unwrap_or_default();
    let remote_message = cx.props.remote_message.unwrap_or_default();

    cx.render(rsx! (
        div {
            class: {
                format_args!(
                    "message-reply {} {}",
                    if loading {
                        "loading"
                    } else { "" },
                    if remote {
                        "remote"
                    } else { "" },
                )
            },
            aria_label: "message-reply",
            (cx.props.user_image.is_some() && remote_message).then(|| rsx! (
                cx.props.user_image.as_ref()
            )),
            (cx.props.with_text.is_some()).then(|| rsx! (
                div {
                    class: "content",
                    (!prefix.is_empty()).then(|| rsx!(
                        p {
                            class: "prefix",
                            "{prefix}"
                        },
                    )),
                    p {
                        class: {
                            format_args!("text {}", if remote_message { "remote-text" } else { "" })
                        },

                        "{text}"
                    }
                }
            )),
            (cx.props.user_image.is_some() && !remote_message).then(|| rsx! (
                cx.props.user_image.as_ref()
            )),
        }
    ))
}
