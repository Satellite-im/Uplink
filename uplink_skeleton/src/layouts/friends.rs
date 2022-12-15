use dioxus::prelude::*;
use ui_kit::{
    elements::{button::Button, Appearance},
    icons::Icon,
};

use crate::components::{
    chat::{sidebar::Sidebar as ChatSidebar, RouteInfo},
    friends::{add::AddFriend, friend::Friends},
};

#[derive(PartialEq, Props)]
pub struct Props {
    route_info: RouteInfo,
}

#[allow(non_snake_case)]
pub fn FriendsLayout(cx: Scope<Props>) -> Element {
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
