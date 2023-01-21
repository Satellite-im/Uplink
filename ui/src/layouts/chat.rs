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
    //println!("rendering Chat layout");
    let state = use_shared_state::<State>(cx)?;
    let first_render = use_state(cx, || true);

    let is_mobile = state.read().ui.is_minimal_view();
    let show_sidebar = !state.read().ui.sidebar_hidden;
    let show_welcome = state.read().chats.active.is_none();
    let render_layout = !(is_mobile && show_sidebar);

    if *first_render.get() && is_mobile {
        state.write().mutate(Action::SidebarHidden(false));
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

            render_layout.then(|| if show_welcome {
                rsx!(Welcome {})
            } else {
                rsx!(Compose {})
            })
        }
    ))
}
