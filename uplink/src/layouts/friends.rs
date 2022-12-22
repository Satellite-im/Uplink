use dioxus::prelude::*;
use fermi::use_atom_ref;
use fluent_templates::Loader;
use ui_kit::{
    elements::{button::Button, Appearance},
    icons::Icon,
};

use crate::{
    components::{
        chat::{sidebar::Sidebar as ChatSidebar, RouteInfo},
        friends::{
            add::AddFriend,
            friend::{BlockedUsers, Friends, OutgoingRequests, PendingFriends},
        },
    },
    state::State,
    APP_LANG, LOCALES, STATE,
};

#[derive(PartialEq, Props)]
pub struct Props {
    route_info: RouteInfo,
}

#[derive(PartialEq)]
pub enum FriendRoute {
    All,
    Pending,
    Blocked,
}

#[allow(non_snake_case)]
pub fn FriendsLayout(cx: Scope<Props>) -> Element {
    let pending_text = LOCALES
        .lookup(&*APP_LANG.read(), "friends.pending")
        .unwrap_or_default();
    let all_text = LOCALES
        .lookup(&*APP_LANG.read(), "friends.all")
        .unwrap_or_default();
    let blocked_text = LOCALES
        .lookup(&*APP_LANG.read(), "friends.blocked")
        .unwrap_or_default();
    let state = use_shared_state::<State>(&cx)?;

    let pending_friends = state.read().friends.incoming_requests.len();

    let route = use_state(&cx, || FriendRoute::All);

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
                        appearance: if route.clone() == FriendRoute::All { Appearance::Primary } else { Appearance::Secondary },
                        onpress: move |_| {
                            route.set(FriendRoute::All);
                        }
                    },
                    Button {
                        icon: Icon::Clock,
                        appearance: if route.clone() == FriendRoute::Pending { Appearance::Primary } else { Appearance::Secondary },
                        text: pending_text,
                        with_badge:  if pending_friends > 0 {
                            pending_friends.to_string()
                        } else {
                            "".into()
                        },
                        onpress: move |_| {
                            route.set(FriendRoute::Pending);
                        }
                    },
                    Button {
                        icon: Icon::NoSymbol,
                        appearance: if route.clone() == FriendRoute::Blocked { Appearance::Primary } else { Appearance::Secondary },
                        text: blocked_text,
                        onpress: move |_| {
                            route.set(FriendRoute::Blocked);
                        }
                    },
                },

                (route.clone() == FriendRoute::All).then(|| rsx!(Friends {})),
                (route.clone() == FriendRoute::Pending).then(|| rsx!(PendingFriends {}, OutgoingRequests {})),
                (route.clone() == FriendRoute::Blocked).then(|| rsx!(BlockedUsers {})),
            }
        }
    ))
}
