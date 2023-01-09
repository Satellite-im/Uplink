use dioxus::prelude::*;
use dioxus_desktop::{use_window, LogicalSize};

use crate::{
    components::chat::{
        compose::Compose, sidebar::Sidebar as ChatSidebar, welcome::Welcome, RouteInfo,
    },
    state::State,
};

#[derive(PartialEq, Props)]
pub struct Props {
    route_info: RouteInfo,
}

#[allow(non_snake_case)]
pub fn ChatLayout(cx: Scope<Props>) -> Element {
    let state = use_shared_state::<State>(cx)?;

    let desktop = use_window(cx);
    desktop.set_inner_size(LogicalSize::new(950.0, 600.0));

    cx.render(rsx!(
        div {
            id: "chat-layout",
            aria_label: "chat-layout",
            span {
                class: "full-width-on-mobile",
                ChatSidebar {
                    route_info: cx.props.route_info.clone()
                },
            },
            state.read().chats.active.is_some().then(|| rsx! (
                Compose {}
            )),
            state.read().chats.active.is_none().then(|| rsx! (
                Welcome {}
            ))
        }
    ))
}
