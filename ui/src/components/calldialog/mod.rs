use common::icons::outline::Shape as Icon;
use common::icons::Icon as IconElement;
use dioxus::prelude::*;
use kit::elements::label::Label;

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
                with_accept_btn,
                with_deny_btn,
            }
        }
    ))
}
