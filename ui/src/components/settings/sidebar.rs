use std::str::FromStr;

use common::icons::outline::Shape as Icon;
use common::language::get_local_text;
use common::sounds;
use common::state::State;
use dioxus::prelude::*;
use dioxus_router::*;
use kit::{
    components::nav::Nav,
    components::nav::Route as UIRoute,
    elements::input::{Input, Options},
    layout::sidebar::Sidebar as ReusableSidebar,
};

use crate::components::chat::RouteInfo;

pub enum Page {
    About,
    Audio,
    Developer,
    Extensions,
    General,
    Files,
    Privacy,
    Profile,
    Notifications,
    Accessibility,
}

impl FromStr for Page {
    fn from_str(input: &str) -> Result<Page, Self::Err> {
        match input {
            "about" => Ok(Page::About),
            "audio" => Ok(Page::Audio),
            "developer" => Ok(Page::Developer),
            "extensions" => Ok(Page::Extensions),
            "files" => Ok(Page::Files),
            "general" => Ok(Page::General),
            "privacy" => Ok(Page::Privacy),
            "profile" => Ok(Page::Profile),
            "notifications" => Ok(Page::Notifications),
            "accessibility" => Ok(Page::Accessibility),
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
    let state = use_shared_state::<State>(cx)?;

    let profile = UIRoute {
        to: "profile",
        name: get_local_text("settings.profile"),
        icon: Icon::User,
        ..UIRoute::default()
    };

    let general = UIRoute {
        to: "general",
        name: get_local_text("settings.general"),
        icon: Icon::Cog6Tooth,
        ..UIRoute::default()
    };

    let audio = UIRoute {
        to: "audio",
        name: get_local_text("settings.audio"),
        icon: Icon::MusicalNote,
        ..UIRoute::default()
    };
    let privacy = UIRoute {
        to: "privacy",
        name: get_local_text("settings.privacy"),
        icon: Icon::LockClosed,
        ..UIRoute::default()
    };
    let files = UIRoute {
        to: "files",
        name: get_local_text("settings.files"),
        icon: Icon::Folder,
        ..UIRoute::default()
    };
    let extensions = UIRoute {
        to: "extensions",
        name: get_local_text("settings.extensions"),
        icon: Icon::Beaker,
        ..UIRoute::default()
    };
    let notifications = UIRoute {
        to: "notifications",
        name: get_local_text("settings-notifications"),
        icon: Icon::BellAlert,
        ..UIRoute::default()
    };
    let accessibility = UIRoute {
        to: "accessibility",
        name: get_local_text("settings.accessibility"),
        icon: Icon::EyeSlash,
        ..UIRoute::default()
    };
    let developer = UIRoute {
        to: "developer",
        name: get_local_text("settings.developer"),
        icon: Icon::CommandLine,
        ..UIRoute::default()
    };
    let about = UIRoute {
        to: "about",
        name: get_local_text("settings.about"),
        icon: Icon::ExclamationCircle,
        ..UIRoute::default()
    };
    let routes = vec![
        profile,
        general,
        privacy,
        audio,
        files,
        extensions,
        accessibility,
        notifications,
        developer,
        about,
    ];

    let active_route = routes[0].clone();

    cx.render(rsx!(
        ReusableSidebar {
            hidden: state.read().ui.sidebar_hidden,
            with_search: cx.render(rsx!(
                div {
                    class: "search-input",
                    Input {
                        placeholder: get_local_text("settings.search-placeholder"),
                        aria_label: "settings-search-input".into(),
                        icon: Icon::MagnifyingGlass,
                        disabled: true,
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
                        if state.read().configuration.audiovideo.interface_sounds {
                            sounds::Play(sounds::Sounds::Interaction);
                        }
                        use_router(cx).replace_route(route, None, None);
                    }
                },
            )),
            Nav {
                routes: routes.clone(),
                active: active_route,
                bubble: true,
                onnavigate: move |route| {
                    if state.read().configuration.audiovideo.interface_sounds {
                       sounds::Play(sounds::Sounds::Interaction);
                    }
                    emit(&cx, Page::from_str(route).unwrap());
                }
            }
        }
    ))
}
