use common::icons::outline::Shape;
use dioxus::prelude::*;

use crate::elements::button::Button;

#[derive(Props, Default)]
pub struct Props<'a> {
    children: Element<'a>,
    on_dismiss: EventHandler<'a, ()>,
    #[props(default = false)]
    is_file_preview: bool,
}

#[allow(non_snake_case)]
pub fn Modal<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let (opacity, size) = if cx.props.is_file_preview {
        ("0", "0px")
    } else {
        ("1", "")
    };

    cx.render(rsx!(
        div {
            class: "modal-wrapper",
            onclick: move |_| cx.props.on_dismiss.call(()),
            div {
                class: "modal",
                width: "{size}",
                height: "{size}",
                onclick: move |evt| {
                    evt.stop_propagation();
                },
                div {
                    class: "modal-content",
                    div {
                        class: "modal-head",
                        opacity: "{opacity}",
                        Button {
                            onpress: move |_| {
                                cx.props.on_dismiss.call(());
                            },
                            icon: Shape::XMark
                        },
                    },
                    div {
                        class: "model-body",
                        rsx!(cx.props.children.as_ref()),
                },
            },
        }
    }
    ))
}
