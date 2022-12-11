use dioxus::desktop::tao;
use dioxus::desktop::tao::dpi::LogicalSize;
use dioxus::prelude::*;

use tao::window::WindowBuilder;
use tao::menu::{MenuBar as Menu, MenuItem};
use store::state::mock_state;
use ui_kit::{icons::Icon, components::nav::Route as UIRoute};

use crate::pages::settings::settings::SettingsPage;
use crate::{layouts::chat::RouteInfo, pages::chat::Page as ChatPage};

const STYLE: &str = include_str!("./style.css");
const LAYOUT_STYLE: &str = include_str!("./layouts/style.css");
const PAGES_STYLE: &str = include_str!("./pages/style.css");

pub mod layouts;
pub mod pages;
pub mod store;
pub mod mock_state;

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


    dioxus::desktop::launch_cfg(app, |c| {
        c.with_window(|_| window.with_menu(main_menu))
    })
}


fn app(cx: Scope) -> Element {
    let _ = use_context_provider(&cx, || mock_state());

    let chat_route = UIRoute { to: "/chat", name: "Chat", icon: Icon::ChatBubbleBottomCenter, ..UIRoute::default() };
    let settings_route = UIRoute { to: "/settings", name: "Settings", icon: Icon::Cog, ..UIRoute::default() };
    let routes = vec![
        chat_route.clone(),
        UIRoute { to: "/files", name: "Files", icon: Icon::Folder, ..UIRoute::default() },
        UIRoute { to: "/friends", name: "Friends", icon: Icon::Users, with_badge: Some("16".into()), loading: None },
        settings_route.clone()
    ];
    cx.render(rsx! (
        style { "{STYLE} {LAYOUT_STYLE} {PAGES_STYLE}" },
        Router {
            Route { 
                to: "/", 
                ChatPage {
                    route_info: RouteInfo {
                        routes: routes.clone(),
                        active: chat_route.clone(),
                    }
                } 
            },
            Route { 
                to: "/settings", 
                SettingsPage {
                    route_info: RouteInfo {
                        routes: routes,
                        active: settings_route.clone(),
                    }
                } 
            }
        }
    ))
}