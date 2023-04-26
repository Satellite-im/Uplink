use common::icons::outline::Shape;
use dioxus::prelude::*;

use crate::elements::button::Button;

#[derive(Props)]
pub struct Props<'a> {
    children: Element<'a>,
    on_dismiss: EventHandler<'a, ()>,
    hidden: bool,
}

#[allow(non_snake_case)]
pub fn Popup<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let full = use_state(&cx, || false);
    let modal = use_state(&cx, || false);
    let show_children = use_state(&cx, || true);

    let full_class = match full.get() {
        true => "popup full",
        false => "popup",
    };

    let hidden_class = match cx.props.hidden {
        true => "hidden",
        false => "show",
    };

    let as_modal = match *modal.clone() {
        true => "as-modal",
        false => "",
    };

    cx.render(rsx!(
        div {
            class: "popup-mask {hidden_class} {as_modal}",
            onclick: move |_| cx.props.on_dismiss.call(()),
            div {
                class: "{full_class} {hidden_class}",
                button {
                    class: "handle",
                    onclick: move |evt| {
                        evt.stop_propagation();
                        full.set(!full.get());
                    }
                }
                div {
                    class: "wrapper",
                    onclick: move |evt| {
                        evt.stop_propagation();
                        full.set(true);
                    },
                    div {
                        class: "controls",
                        Button {
                            onpress: move |_| {
                                modal.set(!modal.clone());
                            },
                            icon: match *modal.clone() {
                                true => Shape::ArrowsPointingIn,
                                false => Shape::ArrowsPointingOut
                            }
                        },
                        Button {
                            onpress: move |_| {
                                cx.props.on_dismiss.call(());
                            },
                            icon: Shape::XMark
                        },
                    },
                    show_children.then(|| rsx!(cx.props.children.as_ref()))
                }
            }
        }
    ))
}
