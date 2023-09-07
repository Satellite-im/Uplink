use dioxus::prelude::*;

use crate::elements::{
    button::Button,
    tooltip::{ArrowPosition, Tooltip},
    Appearance,
};
use common::icons::outline::Shape as Icon;
pub type To = &'static str;

#[derive(Clone)]
pub struct Route<'a> {
    pub to: To,
    pub icon: Icon,
    pub name: String,
    pub with_badge: Option<String>,
    pub loading: Option<bool>,
    pub child: Option<Element<'a>>,
}

impl Default for Route<'_> {
    fn default() -> Self {
        Self {
            to: "",
            icon: Icon::QuestionMarkCircle,
            name: "Default".to_owned(),
            with_badge: None,
            loading: None,
            child: None,
        }
    }
}

#[derive(Props)]
pub struct Props<'a> {
    #[props(optional)]
    onnavigate: Option<EventHandler<'a, To>>,
    routes: Vec<Route<'a>>,
    #[props(optional)]
    active: Option<To>,
    #[props(optional)]
    bubble: Option<bool>,
    pub tooltip_direction: Option<ArrowPosition>,
}

/// Tells the parent the nav was interacted with.
pub fn emit(cx: &Scope<Props>, to: &To) {
    match &cx.props.onnavigate {
        Some(f) => f.call(to.to_owned()),
        None => {}
    }
}

/// Gets the appearance for a nav button based on the active route
pub fn get_appearance(active_route: To, route: To) -> Appearance {
    if active_route == route {
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
pub fn get_active(cx: &Scope<Props>) -> To {
    cx.props.active.unwrap_or("!void")
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
    let tooltip_direction = cx.props.tooltip_direction.unwrap_or(ArrowPosition::Bottom);

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
                // todo: don't show the tooltip if bubble is true
                let tooltip = if cx.props.bubble.is_some() {
                    cx.render(rsx!(""))
                } else {
                    cx.render(rsx!(Tooltip {
                        arrow_position: tooltip_direction,
                        text: route.name.clone(),
                    }))
                };

                rsx!(
                    div {
                        position: "relative",
                        key: "{key}",
                        Button {
                            aria_label: aria_label.to_lowercase() + "-button",
                            icon: route.icon,
                            onpress: move |_| {
                                active.set(route.to);
                                emit(&cx, &route.to)
                            },
                            text: {
                                if bubble { name } else { "".into() }
                            },
                            with_badge: badge,
                            tooltip: tooltip,
                            appearance: get_appearance(active, route.to)
                        },
                        route.child.as_ref().map(|node|{
                            node
                        })
                    }
                )
            })
        }
    ))
}
