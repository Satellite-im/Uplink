use dioxus::desktop::tao;
use dioxus::desktop::tao::dpi::LogicalSize;
use dioxus::prelude::*;

use tao::menu::{MenuBar as Menu, MenuItem};
use tao::window::WindowBuilder;
use ui_kit::{components::nav::Route as UIRoute, icons::Icon};

use ui_kit::STYLE as UIKIT_STYLES;

use crate::layouts::friends::FriendsLayout;
use crate::layouts::settings::settings::SettingsLayout;
use crate::{components::chat::RouteInfo, layouts::chat::ChatLayout};

pub const APP_STYLE: &str = include_str!("./compiled_styles.css");

pub mod components;
pub mod layouts;
pub mod mock;
pub mod state;
pub mod store;
fn main() {
    let mut main_menu = Menu::new();
    let mut app_menu = Menu::new();
    let mut edit_menu = Menu::new();
    let mut window_menu = Menu::new();

    app_menu.add_native_item(MenuItem::Quit);
    app_menu.add_native_item(MenuItem::About(String::from("Uplink")));
    // add native shortcuts to `edit_menu` menu
    // in macOS native item are required to get keyboard shortcut
    // to works correctly
    edit_menu.add_native_item(MenuItem::Undo);
    edit_menu.add_native_item(MenuItem::Redo);
    edit_menu.add_native_item(MenuItem::Separator);
    edit_menu.add_native_item(MenuItem::Cut);
    edit_menu.add_native_item(MenuItem::Copy);
    edit_menu.add_native_item(MenuItem::Paste);
    edit_menu.add_native_item(MenuItem::SelectAll);

    window_menu.add_native_item(MenuItem::Minimize);
    window_menu.add_native_item(MenuItem::Zoom);
    window_menu.add_native_item(MenuItem::Separator);
    window_menu.add_native_item(MenuItem::ShowAll);
    window_menu.add_native_item(MenuItem::EnterFullScreen);
    window_menu.add_native_item(MenuItem::Separator);
    window_menu.add_native_item(MenuItem::CloseWindow);

    main_menu.add_submenu("Uplink", true, app_menu);
    main_menu.add_submenu("Edit", true, edit_menu);
    main_menu.add_submenu("Window", true, window_menu);

    let window = WindowBuilder::new()
        .with_title("Uplink")
        .with_resizable(true)
        .with_inner_size(LogicalSize::new(950.0, 600.0))
        .with_min_inner_size(LogicalSize::new(330.0, 500.0));

    dioxus::desktop::launch_cfg(app, |c| c.with_window(|_| window.with_menu(main_menu)))
}

fn app(cx: Scope) -> Element {
    let _ = use_context_provider(&cx, || store::state::mock());

    let chat_route = UIRoute {
        to: "/",
        name: "Chat",
        icon: Icon::ChatBubbleBottomCenter,
        ..UIRoute::default()
    };
    let settings_route = UIRoute {
        to: "/settings",
        name: "Settings",
        icon: Icon::Cog,
        ..UIRoute::default()
    };
    let friends_route = UIRoute {
        to: "/friends",
        name: "Friends",
        icon: Icon::Users,
        with_badge: Some("16".into()),
        loading: None,
    };
    let routes = vec![
        chat_route.clone(),
        UIRoute {
            to: "/files",
            name: "Files",
            icon: Icon::Folder,
            ..UIRoute::default()
        },
        friends_route.clone(),
        settings_route.clone(),
    ];
    cx.render(rsx! (
        style { "{UIKIT_STYLES} {APP_STYLE}" },
        Router {
            Route {
                to: "/",
                ChatLayout {
                    route_info: RouteInfo {
                        routes: routes.clone(),
                        active: chat_route.clone(),
                    }
                }
            },
            Route {
                to: "/settings",
                SettingsLayout {
                    route_info: RouteInfo {
                        routes: routes.clone(),
                        active: settings_route.clone(),
                    }
                }
            },
            Route {
                to: "/friends",
                FriendsLayout {
                    route_info: RouteInfo {
                        routes: routes,
                        active: friends_route.clone(),
                    }
                }
            }
        }
    ))
}
