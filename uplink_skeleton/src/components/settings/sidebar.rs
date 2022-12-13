use std::str::FromStr;

use dioxus::prelude::*;
use ui_kit::{
    components::nav::Nav,
    components::nav::Route as UIRoute,
    elements::input::{Input, Options},
    icons::Icon,
    layout::sidebar::Sidebar as ReusableSidebar,
};

use crate::components::chat::RouteInfo;

pub enum Page {
    Audio,
    Developer,
    Extensions,
    General,
    Privacy,
}

impl FromStr for Page {
    fn from_str(input: &str) -> Result<Page, Self::Err> {
        match input {
            "audio" => Ok(Page::Audio),
            "developer" => Ok(Page::Developer),
            "extensions" => Ok(Page::Extensions),
            "general" => Ok(Page::General),
            "privacy" => Ok(Page::Privacy),
            _ => Ok(Page::General),
        }
    }

    type Err = ();
}

#[derive(Props)]
pub struct Props<'a> {
    route_info: RouteInfo,
    #[props(optional)]
    onpress: Option<EventHandler<'a, Page>>,
}

pub fn emit(cx: &Scope<Props>, e: Page) {
    match &cx.props.onpress {
        Some(f) => f.call(e),
        None => {}
    }
}

#[allow(non_snake_case)]
pub fn Sidebar<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let search_placeholder = String::from("Search Settings...");
    let general = UIRoute {
        to: "general",
        name: "General",
        icon: Icon::Cog,
        ..UIRoute::default()
    };
    let privacy = UIRoute {
        to: "privacy",
        name: "Privacy",
        icon: Icon::LockClosed,
        ..UIRoute::default()
    };
    let audio = UIRoute {
        to: "audio",
        name: "Audio",
        icon: Icon::MusicalNote,
        ..UIRoute::default()
    };
    let extensions = UIRoute {
        to: "extensions",
        name: "Extensions",
        icon: Icon::Beaker,
        ..UIRoute::default()
    };
    let developer = UIRoute {
        to: "developer",
        name: "Developer",
        icon: Icon::CommandLine,
        ..UIRoute::default()
    };
    let routes = vec![
        general.clone(),
        privacy.clone(),
        audio.clone(),
        extensions.clone(),
        developer.clone(),
    ];

    let active_route = routes[0].clone();
    cx.render(rsx!(
        ReusableSidebar {
            with_search: cx.render(rsx!(
                div {
                    class: "search-input",
                    Input {
                        placeholder: search_placeholder,
                        icon: Icon::MagnifyingGlass,
                        options: Options {
                            with_clear_btn: true,
                            ..Options::default()
                        }
                    }
                }
            ))
            with_nav: cx.render(rsx!(
                Nav {
                    routes: cx.props.route_info.routes.clone(),
                    active: cx.props.route_info.active.clone(),
                    onnavigate: move |route| {
                        use_router(&cx).replace_route(route, None, None);
                    }
                },
            )),
            Nav {
                routes: routes.clone(),
                active: active_route,
                bubble: true,
                onnavigate: move |route| {
                    emit(&cx, Page::from_str(route).unwrap());
                }
            }
        }
    ))
}
