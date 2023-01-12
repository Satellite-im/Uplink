use dioxus::prelude::*;

use crate::{
    components::chat::{
        compose::Compose, sidebar::Sidebar as ChatSidebar, welcome::Welcome, RouteInfo,
    },
    state::{Action, State},
};

#[derive(PartialEq, Props)]
pub struct Props {
    route_info: RouteInfo,
}

#[allow(non_snake_case)]
pub fn ChatLayout(cx: Scope<Props>) -> Element {
    let state = use_shared_state::<State>(cx)?;

    let first_render = use_state(cx, || true);
    if *first_render.clone() && state.read().ui.is_minimal_view() {
        state.write().mutate(Action::SidebarHidden(false));
        first_render.set(false);
    }

    cx.render(rsx!(
        div {
            id: "chat-layout",
            aria_label: "chat-layout",
            ChatSidebar {
                route_info: cx.props.route_info.clone()
            },
            (state.read().ui.is_minimal_view() && state.read().ui.sidebar_hidden || !state.read().ui.is_minimal_view()).then(|| rsx!(
                state.read().chats.active.is_some().then(|| rsx! (
                    Compose {}
                )),
                state.read().chats.active.is_none().then(|| rsx! (
                    Welcome {}
                ))
            ))
        }
    ))
}
