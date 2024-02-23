use std::time::Duration;

use crate::layouts::chats::ChatSidebar;
use crate::{
    components::friends::{
        add::AddFriend, blocked::BlockedUsers, friends_list::Friends,
        incoming_requests::PendingFriends, nothing_here::NothingHere,
        outgoing_requests::OutgoingRequests,
    },
    layouts::slimbar::SlimbarLayout,
};
use common::icons::outline::Shape as Icon;
use common::state::{ui, Action, State};
use common::{
    language::get_local_text,
    notifications::{NotificationAction, NOTIFICATION_LISTENER},
};
use dioxus::prelude::*;
use kit::{
    elements::{button::Button, Appearance},
    layout::topbar::Topbar,
};
use tokio::sync::broadcast::error::RecvError;
use tracing::log;

#[derive(PartialEq, Clone)]
pub enum FriendRoute {
    All,
    Pending,
    Blocked,
}

#[allow(non_snake_case)]
pub fn FriendsLayout() -> Element {
    let state = use_shared_state::<State>(cx)?;
    let route = use_state(cx, || FriendRoute::All);
    let show_slimbar = state.read().show_slimbar() & !state.read().ui.is_minimal_view();
    state.write_silent().ui.current_layout = ui::Layout::Friends;

    if state.read().ui.is_minimal_view() {
        return cx.render(rsx!(MinimalFriendsLayout { route: route }));
    }
    log::trace!("rendering FriendsLayout");

    // this is a hack to deal with a change in how Dioxus routing works. The `route` hook used to be shared
    // between elements.
    use_future(cx, (), |_| {
        to_owned![route];
        async move {
            let mut ch = NOTIFICATION_LISTENER.tx.subscribe();
            log::trace!("starting notification action listener");
            loop {
                let cmd = match ch.recv().await {
                    Ok(cmd) => cmd,
                    Err(RecvError::Closed) => {
                        log::debug!("RecvError::Closed while reading from NOTIFICATION_LISTENER");
                        return;
                    }
                    _ => {
                        tokio::time::sleep(Duration::from_millis(100)).await;
                        continue;
                    }
                };
                log::debug!("handling notification action {:#?}", cmd);
                match cmd {
                    NotificationAction::FriendListPending => {
                        route.set(FriendRoute::Pending);
                    }
                    NotificationAction::Dummy => {}
                    _ => {}
                }
            }
        }
    });

    cx.render(rsx!(
        div {
            id: "friends-layout",
            aria_label: "friends-layout",
            class: "disable-select",
            if show_slimbar {
                cx.render(rsx!(
                    SlimbarLayout { active: crate::UplinkRoute::FriendsLayout {} },
                ))
            },
            ChatSidebar {
                active_route: crate::UplinkRoute::FriendsLayout {},
            },
            div {
                class: "friends-body",
                aria_label: "friends-body",
                get_topbar(cx, route),
                AddFriend {},
                // TODO: Will need to determine if we're loading or not once state is update, and display a loading view if so. (see friends-list)
                render_route(cx, route.get().clone()),
            }
        }
    ))
}

#[derive(PartialEq, Props)]
pub struct MinimalProps<'a> {
    route: &'a UseState<FriendRoute>,
}

#[allow(non_snake_case)]
pub fn MinimalFriendsLayout<'a>(props: 'a, MinimalProps) -> Element {
    log::trace!("rendering MinimalFriendsLayout");
    let state = use_shared_state::<State>(cx)?;
    let route = props.route;

    let view = if !state.read().ui.sidebar_hidden {
        rsx!(ChatSidebar {
            active_route: crate::UplinkRoute::FriendsLayout {},
        })
    } else {
        rsx!(
            div {
                class: "friends-body",
                aria_label: "friends-body",
                get_topbar(cx, route),
                AddFriend {},
                div {
                    class: "friends-controls",
                    aria_label: "friends-controls",
                },
                // TODO: Will need to determine if we're loading or not once state is update, and display a loading view if so. (see friends-list)
                render_route(cx, route.get().clone()),
                crate::AppNav {
                    active: crate::UplinkRoute::FriendsLayout{},
                }
            }
        )
    };

    cx.render(rsx!(div {
        id: "friends-layout",
        aria_label: "friends-layout",
        view
    }))
}

fn render_route<T>(props: T, route: FriendRoute) -> Element {
    cx.render(rsx!(match route {
        FriendRoute::All => rsx!(Friends {}),
        FriendRoute::Pending => rsx!(
            PendingFriends {},
            OutgoingRequests {},
            NothingHere {
                friends_tab: "Pending".into()
            }
        ),
        FriendRoute::Blocked => rsx!(
            BlockedUsers {},
            NothingHere {
                friends_tab: "Blocked".into()
            }
        ),
    }))
}

fn get_topbar<'a, T>(props: 'a, T>, route: &'a UseState<FriendRoute) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let pending_friends = state.read().friends().incoming_requests.len();

    cx.render(rsx!(Topbar {
        with_back_button: state.read().ui.is_minimal_view() && state.read().ui.sidebar_hidden,
        onback: move |_| {
            let current = state.read().ui.sidebar_hidden;
            state.write().mutate(Action::SidebarHidden(!current));
        },
        controls: cx.render(rsx!(
            Button {
                icon: Icon::Users,
                text: if state.read().ui.is_minimal_view() {
                    "".into()
                } else {
                    get_local_text("friends.all")
                },
                aria_label: "all-friends-button".into(),
                appearance: if route.clone() == FriendRoute::All {
                    Appearance::Primary
                } else {
                    Appearance::Secondary
                },
                onpress: move |_| {
                    route.set(FriendRoute::All);
                }
            },
            Button {
                icon: Icon::Clock,
                appearance: if route.clone() == FriendRoute::Pending {
                    Appearance::Primary
                } else {
                    Appearance::Secondary
                },
                text: if state.read().ui.is_minimal_view() {
                    "".into()
                } else {
                    get_local_text("friends.pending")
                },
                aria_label: "pending-friends-button".into(),
                with_badge: if pending_friends > 0 {
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
                appearance: if route.clone() == FriendRoute::Blocked {
                    Appearance::Primary
                } else {
                    Appearance::Secondary
                },
                text: if state.read().ui.is_minimal_view() {
                    "".into()
                } else {
                    get_local_text("friends.blocked")
                },
                aria_label: "blocked-friends-button".into(),
                onpress: move |_| {
                    route.set(FriendRoute::Blocked);
                }
            },
        ))
    },))
}
