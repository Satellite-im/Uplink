use dioxus::prelude::*;

#[derive(Props)]
pub struct Props<'a> {
    classes: Option<String>,
    onclose: EventHandler<()>,
    children: Option<Element>,
}

#[allow(non_snake_case)]
pub fn InvisibleCloser<'a>(cx: Scope<'a, Props<'a>>) -> Element {
    cx.render(rsx!(div {
        class: format_args!(
            "close-handler-behind {}",
            cx.props.classes.clone().unwrap_or_default()
        ),
        onclick: move |_| {
            cx.props.onclose.call(());
        },
        cx.props.children.as_ref()
    }))
}
