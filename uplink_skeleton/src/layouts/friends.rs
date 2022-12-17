use dioxus::prelude::*;
use fluent_templates::Loader;
use ui_kit::{
    elements::{button::Button, Appearance},
    icons::Icon,
};

use crate::{
    components::{
        chat::{sidebar::Sidebar as ChatSidebar, RouteInfo},
        friends::{add::AddFriend, friend::Friends},
    },
    state::State,
    LOCALES, US_ENGLISH,
};

#[derive(PartialEq, Props)]
pub struct Props {
    route_info: RouteInfo,
}

#[allow(non_snake_case)]
pub fn FriendsLayout(cx: Scope<Props>) -> Element {
    let pending_text = LOCALES
        .lookup(&US_ENGLISH, "friends.pending")
        .unwrap_or_default();
    let all_text = LOCALES
        .lookup(&US_ENGLISH, "friends.all")
        .unwrap_or_default();
    let blocked_text = LOCALES
        .lookup(&US_ENGLISH, "friends.blocked")
        .unwrap_or_default();
    let state: UseSharedState<State> = use_context::<State>(&cx).unwrap();

    let pending_friends = state.read().friends.incoming_requests.len();

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
                        text: all_text,
                    },
                    Button {
                        icon: Icon::Clock,
                        appearance: Appearance::Secondary,
                        text: pending_text,
                        with_badge:  if pending_friends > 0 {
                            pending_friends.to_string()
                        } else {
                            "".into()
                        },
                    },
                    Button {
                        icon: Icon::NoSymbol,
                        appearance: Appearance::Secondary,
                        text: blocked_text,
                    },
                },
                Friends {}
            }
        }
    ))
}
