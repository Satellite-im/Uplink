use dioxus::prelude::*;

#[derive(Props)]
pub struct Props<'a> {
    onclose: EventHandler<'a, ()>,
}

#[allow(non_snake_case)]
pub fn InvisibleCloser<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    cx.render(rsx!(div {
        class: "close-handler-behind",
        onclick: move |_| {
            cx.props.onclose.call(());
        }
    }))
}
