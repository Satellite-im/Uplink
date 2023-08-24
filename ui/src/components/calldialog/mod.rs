use common::icons::outline::Shape as Icon;
use dioxus::prelude::*;

#[derive(Props)]
pub struct Props<'a> {
    caller: Element<'a>,
    icon: Icon,
    description: String,
    usernames: String,
    in_chat: bool,
    #[props(optional)]
    with_accept_btn: Option<Element<'a>>,
    #[props(optional)]
    with_deny_btn: Option<Element<'a>>,
}

// todo: remove this
#[allow(unused)]
#[allow(non_snake_case)]
pub fn CallDialog<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let with_accept_btn = match cx.props.with_accept_btn.clone() {
        Some(w_a_b) => w_a_b,
        None => None,
    };
    let with_deny_btn = match cx.props.with_deny_btn.clone() {
        Some(w_d_b) => w_d_b,
        None => None,
    };
    cx.render(rsx! (
        div {
            class:format_args!("call-dialog {}", if cx.props.in_chat {"in-chat"} else {""}),
            div {
                class: "call-information",
                rsx!(
                    common::icons::Icon {
                        ..common::icons::IconProps {
                            class: None,
                            size: 20,
                            fill:"currentColor",
                            icon: cx.props.icon,
                            disabled: false,
                            disabled_fill: "#9CA3AF"
                        },
                    },
                )
                p {
                    "{cx.props.description}",
                }
            },
            div {
                class: "calling",
                div {
                    class: "user-group-scale",
                    &cx.props.caller,
                }
            },
            (!cx.props.in_chat).then(||rsx!(div {
                class: "users",
                "{cx.props.usernames}",
            }))
            div {
                class: "controls",
                with_accept_btn,
                with_deny_btn,
            }
        }
    ))
}
