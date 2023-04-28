use common::icons::outline::Shape;
use dioxus::prelude::*;

use crate::elements::button::Button;

#[derive(Props)]
pub struct Props<'a> {
    children: Element<'a>,
    on_dismiss: EventHandler<'a, ()>,
}

#[allow(non_snake_case)]
pub fn Modal<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    cx.render(rsx!(
        div {
            class: "modal-wrapper",
            onclick: move |_| cx.props.on_dismiss.call(()),
            div {
                class: "modal",
                onclick: move |evt| {
                    evt.stop_propagation();
                },
                div {
                    class: "controls",
                    Button {
                        onpress: move |_| {
                            cx.props.on_dismiss.call(());
                        },
                        icon: Shape::XMark
                    },
                },
                div {
                    class: "content",
                    rsx!(cx.props.children.as_ref())
                }

            }
        }
    ))
}
