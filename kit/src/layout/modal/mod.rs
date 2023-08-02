use crate::components::context_menu::ContextMenu;
use crate::elements::button::Button;
use crate::elements::Appearance;
use common::icons::outline::Shape as Icon;

use dioxus::prelude::*;

#[derive(Props)]
pub struct Props<'a> {
    open: bool,
    children: Element<'a>,
    onclose: EventHandler<'a, ()>,
}

#[allow(non_snake_case)]
pub fn Modal<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    cx.render(rsx!(cx.props.open.then(|| rsx!(
        ContextMenu {
            key: "modal-test",
            id: "file-embed-preview-context-menu".into(),
            items: cx.render(rsx!(
                div {},
            )),
            div {
                class: "modal",
                aria_label: "modal",
                onclick: move |_| cx.props.onclose.call(()),
                Button {
                    icon: Icon::XMark,
                    appearance: Appearance::Primary,
                    onpress: move |_| cx.props.onclose.call(()),
                },
                &cx.props.children
            },
        }
    ))))
}
