use dioxus::prelude::*;

use crate::components::{
    indicator::{Platform, Status},
    user_image::UserImage,
};

#[derive(Props)]
pub struct Props<'a> {
    children: Element<'a>,
    user_image: Element<'a>,
    sender: String,
    #[props(optional)]
    remote: Option<bool>,
    #[props(optional)]
    timestamp: Option<String>,
    #[props(optional)]
    with_sender: Option<Element<'a>>,
}

#[allow(non_snake_case)]
pub fn MessageGroup<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let remote = cx.props.remote.unwrap_or_default();
    let time_ago = cx.props.timestamp.clone().unwrap_or_default();

    cx.render(rsx! (
        div {
            class: "message-group-wrap",
            aria_label: "message-group-wrap",
            remote.then(|| rsx!(
                &cx.props.user_image
            ))
            div {
                class: {
                    format_args!("message-group {}", if remote { "remote" } else { "" })
                },
                aria_label: {
                    format_args!("message-group{}", if remote { "-remote" } else { "" })
                },
                &cx.props.children,
                p {
                    class: "time-ago noselect defaultcursor",
                    aria_label: "time-ago",
                    "{cx.props.sender} - {time_ago}"
                }
                cx.props.with_sender.as_ref()
            }
            (!remote).then(|| rsx!(
                &cx.props.user_image
            ))
        }
    ))
}

#[derive(PartialEq, Props)]
pub struct SkeletalProps {
    #[props(optional)]
    alt: Option<bool>,
}

#[allow(non_snake_case)]
pub fn MessageGroupSkeletal(cx: Scope<SkeletalProps>) -> Element {
    let alt = cx.props.alt.unwrap_or_default();

    cx.render(rsx!(
        div {
            class: format_args!("message-group-skeletal {}", if alt { "alt" } else { "" }),
            UserImage {
                loading: true,
                status: Status::Offline,
                platform: Platform::Desktop
            },
            div {
                class: "skeletal-messages",
                div {
                    class: "skeletal-message",
                    div {
                        class: "skeletal-message-content skeletal",
                    }
                },
                div {
                    class: "skeletal-message",
                    div {
                        class: "skeletal-message-content skeletal",
                    }
                },
                div {
                    class: "skeletal-message",
                    div {
                        class: "skeletal-message-content skeletal",
                    }
                },
                div {
                    class: "skeletal-timestamp"
                }
            }
        }
    ))
}
