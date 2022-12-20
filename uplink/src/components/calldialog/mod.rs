use dioxus::prelude::*;
use ui_kit::{
    elements::label::Label,
    icons::{Icon, IconElement},
};

#[derive(Props)]
pub struct Props<'a> {
    caller: Element<'a>,
    callee: Element<'a>,
    description: String,
    #[props(optional)]
    with_accept_btn: Option<Element<'a>>,
    #[props(optional)]
    with_deny_btn: Option<Element<'a>>,
}

#[allow(non_snake_case)]
pub fn CallDialog<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    cx.render(rsx! (
        div {
            class: "call-dialog",
            div {
                class: "calling",
                &cx.props.callee,
                span {
                    class: "connecting",
                    IconElement {
                        icon: Icon::ArrowsRightLeft
                    }
                },
                &cx.props.caller,
            },
            div {
                class: "call-information",
                Label {
                    text: "Calling...".into(),
                },
                p {
                    "{cx.props.description}",
                }
            },
            div {
                class: "controls",
                &cx.props.with_accept_btn,
                &cx.props.with_deny_btn,
            }
        }
    ))
}
