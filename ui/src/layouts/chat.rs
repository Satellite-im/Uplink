use dioxus::prelude::*;

use crate::components::chat::{
    compose::Compose, sidebar::Sidebar as ChatSidebar, welcome::Welcome, RouteInfo,
};
use common::state::{ui, Action, State};

#[derive(PartialEq, Props)]
pub struct Props {
    route_info: RouteInfo,
}

#[allow(non_snake_case)]
pub fn ChatLayout(cx: Scope<Props>) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let first_render = use_state(cx, || true);

    state.write_silent().ui.current_layout = ui::Layout::Welcome;

    let is_minimal_view = state.read().ui.is_minimal_view();
    let sidebar_hidden = state.read().ui.sidebar_hidden;
    let show_welcome = state.read().chats().active.is_none();

    if *first_render.get() && is_minimal_view {
        state.write().mutate(Action::SidebarHidden(true));
        first_render.set(false);
    }

    cx.render(rsx!(
        div {
            id: "chat-layout",
            aria_label: "chat-layout",
            // todo: consider showing a welcome screen if the sidebar is to be shown but there are no conversations in the sidebar. this case arises when
            // creating a new account on a mobile device.
            ChatSidebar {
                route_info: cx.props.route_info.clone()
            },
            show_welcome.then(|| rsx!(Welcome {})),
            (!show_welcome && (sidebar_hidden || !state.read().ui.is_minimal_view())).then(|| rsx!(Compose {}))
        }
    ))
}
