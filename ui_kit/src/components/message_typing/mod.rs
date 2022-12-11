use dioxus::prelude::*;

#[derive(Props)]
pub struct Props<'a> {
    user_image: Element<'a>,
}


#[allow(non_snake_case)]
pub fn MessageTyping<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    cx.render(rsx! (
        div {
            class: "message-typing-wrap",
            // TODO: Support a vec of user images in case multiple are typing
            &cx.props.user_image,
            div {
                class: "message-typing",
                div { class: "dot dot-1" },
                div { class: "dot dot-2" },
                div { class: "dot dot-3" }
            }
        }
    ))
}