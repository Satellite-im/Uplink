use dioxus::prelude::*;

use crate::components::chat::{compose::Compose, sidebar::Sidebar as ChatSidebar, RouteInfo};

#[derive(PartialEq, Props)]
pub struct Props {
    route_info: RouteInfo,
}

#[allow(non_snake_case)]
pub fn ChatLayout(cx: Scope<Props>) -> Element {
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
