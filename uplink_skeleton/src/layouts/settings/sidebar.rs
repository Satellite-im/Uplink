use dioxus::prelude::*;
use ui_kit::{elements::input::{Input, Options}, icons::Icon, components::nav::Nav, layout::sidebar::Sidebar, components::nav::Route as UIRoute};

use crate::layouts::chat::RouteInfo;

#[derive(PartialEq, Props)]
pub struct Props {
    route_info: RouteInfo,
}

#[allow(non_snake_case)]
pub fn SettingsSidebar(cx: Scope<Props>) -> Element {
    let search_placeholder = String::from("Search Settings...");
    let general = UIRoute { to: "general", name: "General", icon: Icon::Cog, ..UIRoute::default() };
    let privacy = UIRoute { to: "privacy", name: "Privacy", icon: Icon::LockClosed, ..UIRoute::default() };
    let audio = UIRoute { to: "audio", name: "Audio", icon: Icon::MusicalNote, ..UIRoute::default() };
    let extensions = UIRoute { to: "extensions", name: "Extensions", icon: Icon::Beaker, ..UIRoute::default() };
    let developer = UIRoute { to: "developer", name: "Developer", icon: Icon::CommandLine, ..UIRoute::default() };
    let routes = vec![
        general.clone(),
        privacy.clone(),
        audio.clone(),
        extensions.clone(),
        developer.clone(),
    ];

    let active_route = routes[0].clone();
    cx.render(rsx!(
        Sidebar {
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
                    onnavigate: move |r| {
                        use_router(&cx).replace_route(r, None, None);
                    }
                },
            )),
            Nav {
                routes: routes.clone(),
                active: active_route,
                bubble: true,
                onnavigate: move |_| {}
            }
        }
    ))
}
