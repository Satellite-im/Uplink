use dioxus::prelude::*;
use uuid::Uuid;

use crate::{Icon, IconElement, elements::button::{Button, Appearance}};

pub type To = String;

const STYLE: &'static str = include_str!("./style.css");

#[derive(Clone, PartialEq)]
pub struct Route {
    pub to: To,
    pub icon: Icon,
    pub name: String,
}

#[derive(Props)]
pub struct Props<'a> {
    #[props(optional)]
    onnavigate: Option<EventHandler<'a, To>>,
    routes: Vec<Route>,
    #[props(optional)]
    active: Option<Route>
}

/// Tells the parent the nav was interacted with.
pub fn emit(cx: &Scope<Props>, to: &To) {
    match &cx.props.onnavigate {
        Some(f) => f.call(to.to_owned()),
        None => {},
    }
}

pub fn get_appearence(active_route: &Route, route: &Route) -> Appearance {
    if active_route.to == route.to {
        Appearance::Primary
    } else {
        Appearance::Transparent
    }
}

pub fn get_active(cx: &Scope<Props>) -> Route {
    match &cx.props.active {
        Some(f) => f.to_owned(),
        None => Route {
            to: String::from("void"),
            name: String::from("void"),
            icon: Icon::ExclamationTriangle
        },
    }
}

#[allow(non_snake_case)]
pub fn Nav<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let active = use_state(&cx, || get_active(&cx));

    cx.render(
        rsx!(
            style { "{STYLE}" }
            div {
                class: "nav",
                cx.props.routes.iter().map(|route| rsx!(
                    Button {
                        key: "{route.to}-{route.name}",
                        icon: route.icon,
                        onpress: move |_| {
                            active.set(route.to_owned());
                            emit(&cx, &route.to)
                        },
                        appearance: get_appearence(&active, &route)
                    }
                ))
            }
        )
    )
}