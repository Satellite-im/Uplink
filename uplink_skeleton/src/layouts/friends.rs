use dioxus::prelude::*;

use crate::{
    components::{
        chat::{compose::Compose, sidebar::Sidebar as ChatSidebar, welcome::Welcome, RouteInfo},
        friends::add::AddFriend,
    },
    store::state::State,
};

#[derive(PartialEq, Props)]
pub struct Props {
    route_info: RouteInfo,
}

#[allow(non_snake_case)]
pub fn FriendsLayout(cx: Scope<Props>) -> Element {
    let state: UseSharedState<State> = use_context::<State>(&cx).unwrap();

    cx.render(rsx!(
        div {
            id: "friends-layout",
            ChatSidebar {
                route_info: cx.props.route_info.clone()
            },
            AddFriend {}
        }
    ))
}
