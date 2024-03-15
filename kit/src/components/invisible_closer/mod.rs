use dioxus::prelude::*;

#[derive(Props, Clone, PartialEq)]
pub struct Props {
    classes: Option<String>,
    onclose: EventHandler<()>,
    children: Option<Element>,
}

#[allow(non_snake_case)]
pub fn InvisibleCloser(props: Props) -> Element {
    rsx!(div {
        class: format_args!(
            "close-handler-behind {}",
            props.classes.clone().unwrap_or_default()
        ),
        onclick: move |_| {
            props.onclose.call(());
        },
        {props.children.as_ref()}
    })
}
