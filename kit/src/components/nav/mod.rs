use dioxus::prelude::*;

use crate::elements::{
    button::Button,
    tooltip::{ArrowPosition, Tooltip},
    Appearance,
};
use common::icons::outline::Shape as Icon;
pub type To = &'static str;

#[derive(Clone, PartialEq)]
pub struct Route {
    pub to: To,
    pub icon: Icon,
    pub name: String,
    pub with_badge: Option<String>,
    pub loading: Option<bool>,
}

impl Default for Route {
    fn default() -> Self {
        Self {
            to: "",
            icon: Icon::QuestionMarkCircle,
            name: "Default".to_owned(),
            with_badge: None,
            loading: None,
        }
    }
}

#[derive(Props)]
pub struct Props<'a> {
    #[props(optional)]
    onnavigate: Option<EventHandler<'a, To>>,
    routes: Vec<Route>,
    #[props(optional)]
    active: Option<Route>,
    #[props(optional)]
    bubble: Option<bool>,
}

/// Tells the parent the nav was interacted with.
pub fn emit(cx: &Scope<Props>, to: &To) {
    match &cx.props.onnavigate {
        Some(f) => f.call(to.to_owned()),
        None => {}
    }
}

/// Gets the appearance for a nav button based on the active route
pub fn get_appearance(active_route: &Route, route: &Route) -> Appearance {
    if active_route.to == route.to {
        Appearance::Primary
    } else {
        Appearance::Transparent
    }
}

/// Generates the an optional badge value
pub fn get_badge(route: &Route) -> String {
    route.with_badge.clone().unwrap_or_default()
}

/// Gets the active route, or returns a void one
pub fn get_active(cx: &Scope<Props>) -> Route {
    match &cx.props.active {
        Some(f) => f.to_owned(),
        None => Route {
            to: "!void",
            name: "!void".to_owned(),
            icon: Icon::ExclamationTriangle,
            with_badge: None,
            loading: None,
        },
    }
}

/// Returns a nav component generated based on given props.
///
/// # Examples
/// ```no_run
/// use dioxus::prelude::*;
/// use kit::{elements::{Icon, IconElement}, components::nav::{Nav, Route}};
///
/// let home = Route { to: "/fake/home", name: "Home", icon: Icon::HomeModern };
/// let routes = vec![
///     home,
///     Route { to: "/fake/chat", name: "Chat", icon: Icon::ChatBubbleBottomCenter },
///     Route { to: "/fake/friends", name: "Friends", icon: Icon::Users },
///     Route { to: "/fake/settings", name: "Settings", icon: Icon::Cog6Tooth },
/// ];
/// let active = routes[0].clone();
///
/// rsx! (
///     Nav {
///        routes: routes,
///        active: active
///    }
/// )
/// ```
#[allow(non_snake_case)]
pub fn Nav<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let active = use_state(cx, || get_active(&cx));
    let bubble = cx.props.bubble.unwrap_or_default();

    cx.render(rsx!(
        div {
            aria_label: "button-nav",
            class: {
                format_args!("nav {}", if bubble { "bubble" } else { "" })
            },
            cx.props.routes.iter().map(|route| {
                let badge = get_badge(route);
                let key: String = route.name.clone();
                let name: String = route.name.clone();
                let aria_label: String = route.name.clone();
                rsx!(
                    Button {
                        key: "{key}",
                        aria_label: aria_label.to_lowercase() + "-button",
                        icon: route.icon,
                        onpress: move |_| {
                            active.set(route.to_owned());
                            emit(&cx, &route.to)
                        },
                        text: {
                            if bubble { name } else { "".into() }
                        },
                        with_badge: badge,
                        tooltip: cx.render(rsx!(
                            (!bubble).then(|| rsx!(
                                Tooltip {
                                    arrow_position: ArrowPosition::Bottom,
                                    text: route.name.clone(),
                                }
                            ))
                        )),
                        appearance: get_appearance(active, route)
                    }
                )
            })
        }
    ))
}
