use dioxus::prelude::*;
use ui_kit::{
    elements::{button::Button, label::Label, Appearance},
    icons::{Icon, IconElement},
};

use crate::{
    components::{
        chat::{compose::Compose, sidebar::Sidebar as ChatSidebar, welcome::Welcome, RouteInfo},
        friends::{add::AddFriend, friend::Friends},
    },
    state::State,
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
            div {
                class: "friends-body",
                AddFriend {},
                div {
                    class: "friends-controls",
                    Button {
                        icon: Icon::User,
                        text: "All".into(),
                    },
                    Button {
                        icon: Icon::Clock,
                        appearance: Appearance::Secondary,
                        text: "Pending".into(),
                    },
                    Button {
                        icon: Icon::NoSymbol,
                        appearance: Appearance::Secondary,
                        text: "Blocked".into(),
                    },
                },
                Friends {}
            }
        }
    ))
}
