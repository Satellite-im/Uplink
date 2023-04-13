use common::language::get_local_text;
use dioxus::prelude::*;
use dioxus_router::*;
use kit::{
    components::nav::Nav,
    elements::{button::Button, Appearance},
    layout::topbar::Topbar,
};
use warp::logging::tracing::log;

use crate::components::{
    chat::{sidebar::Sidebar as ChatSidebar, RouteInfo},
    friends::{
        add::AddFriend, blocked::BlockedUsers, friends_list::Friends,
        incoming_requests::PendingFriends, outgoing_requests::OutgoingRequests,
    },
};
use common::icons::outline::Shape as Icon;
use common::state::{ui, Action, State};

#[derive(PartialEq, Props)]
pub struct Props {
    route_info: RouteInfo,
}

#[derive(PartialEq, Clone)]
pub enum FriendRoute {
    All,
    Pending,
    Blocked,
}

#[allow(non_snake_case)]
pub fn FriendsLayout(cx: Scope<Props>) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let route = use_state(cx, || FriendRoute::All);

    state.write_silent().ui.current_layout = ui::Layout::Friends;

    if state.read().ui.is_minimal_view() {
        return cx.render(rsx!(MinimalFriendsLayout {
            route: route,
            route_info: cx.props.route_info.clone()
        }));
    }
    log::trace!("rendering FriendsLayout");

    cx.render(rsx!(
        div {
            id: "friends-layout",
            aria_label: "friends-layout",
            ChatSidebar {
                route_info: cx.props.route_info.clone()
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
    route_info: RouteInfo,
}

#[allow(non_snake_case)]
pub fn MinimalFriendsLayout<'a>(cx: Scope<'a, MinimalProps>) -> Element<'a> {
    log::trace!("rendering MinimalFriendsLayout");
    let state = use_shared_state::<State>(cx)?;
    let route = cx.props.route;

    let view = if !state.read().ui.sidebar_hidden {
        rsx!(ChatSidebar {
            route_info: cx.props.route_info.clone()
        },)
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
                Nav {
                    routes: cx.props.route_info.routes.clone(),
                    active: cx.props.route_info.active.clone(),
                    onnavigate: move |r| {
                        use_router(cx).replace_route(r, None, None);
                    }
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

fn render_route<T>(cx: Scope<T>, route: FriendRoute) -> Element {
    cx.render(rsx!(match route {
        FriendRoute::All => rsx!(Friends {}),
        FriendRoute::Pending => rsx!(PendingFriends {}, OutgoingRequests {}),
        FriendRoute::Blocked => rsx!(BlockedUsers {}),
    }))
}

fn get_topbar<'a, T>(cx: Scope<'a, T>, route: &'a UseState<FriendRoute>) -> Element<'a> {
    let state = use_shared_state::<State>(cx)?;
    let pending_friends = state.read().friends().incoming_requests.len();

    cx.render(rsx!(Topbar {
        with_back_button: state.read().ui.is_minimal_view() || state.read().ui.sidebar_hidden,
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
