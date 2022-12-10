use dioxus::prelude::*;

use crate::layouts::chat::{sidebar::Sidebar as ChatSidebar, RouteInfo, compose::Compose};

#[derive(PartialEq, Props)]
pub struct Props {
    route_info: RouteInfo,
}

#[allow(non_snake_case)]
pub fn Page(cx: Scope<Props>) -> Element {
    cx.render(rsx!(
        div {
            id: "chat-page",
            ChatSidebar {
                route_info: cx.props.route_info.clone()
            },
            Compose {},
        }
    ))
}
