//#![deny(elided_lifetimes_in_paths)]

use clap::Parser;
use config::Configuration;
use dioxus::prelude::*;
use dioxus_desktop::tao::dpi::LogicalSize;
use dioxus_desktop::tao::menu::AboutMetadata;
use dioxus_desktop::Config;
use dioxus_desktop::{tao, use_window};
use fs_extra::dir::*;
use kit::elements::Appearance;
use kit::icons::IconElement;
use kit::{components::nav::Route as UIRoute, icons::Icon};
use overlay::{make_config, OverlayDom};
use shared::language::{change_language, get_local_text};
// use state::{Action, ActionHook, State};
use state::State;
use std::path::{Path, PathBuf};

use std::sync::Arc;
use tao::menu::{MenuBar as Menu, MenuItem};
use tao::window::WindowBuilder;
use tokio::sync::Mutex;
use tokio::time::{sleep, Duration};
use warp::logging::tracing::log;

use crate::components::toast::Toast;
use crate::layouts::auth::AuthLayout;
use crate::layouts::files::FilesLayout;
use crate::layouts::friends::FriendsLayout;
use crate::layouts::settings::SettingsLayout;
use crate::layouts::unlock::UnlockLayout;
use crate::warp_runner::{WarpCmdRx, WarpCmdTx, WarpEventRx, WarpEventTx};
use crate::{components::chat::RouteInfo, layouts::chat::ChatLayout};
use dioxus_router::*;

use kit::STYLE as UIKIT_STYLES;
pub const APP_STYLE: &str = include_str!("./compiled_styles.css");
pub mod components;
pub mod config;
pub mod layouts;
pub mod overlay;
pub mod state;
pub mod testing;
pub mod utils;
mod warp_runner;

#[macro_use]
extern crate lazy_static;

#[derive(Debug)]
pub struct StaticArgs {
    pub uplink_path: PathBuf,
    pub warp_path: PathBuf,
    pub use_mock: bool,
}

lazy_static! {
    pub static ref STATIC_ARGS: StaticArgs = {
        let args = Args::parse();
        let uplink_path = match args.path {
            Some(path) => path,
            _ => dirs::home_dir().unwrap_or_default().join(".uplink"),
        };
        StaticArgs {
            uplink_path: uplink_path.clone(),
            warp_path: uplink_path.join("warp"),
            use_mock: args.mock,
        }
    };

    // allows the UI to send commands to Warp
    pub static ref WARP_CMD_CH: (WarpCmdTx, WarpCmdRx) = {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        (tx, Arc::new(Mutex::new(rx)))
    };

    // allows the UI to receive events to Warp
    // pretty sure the rx channel needs to be in a mutex in order for it to be a static mutable variable
    pub static ref WARP_CHANNELS: (WarpEventTx, WarpEventRx) =  {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        (tx, Arc::new(Mutex::new(rx)))
    };
}

pub static CHAT_ROUTE: &str = "/chat";
pub static FRIENDS_ROUTE: &str = "/friends";
pub static FILES_ROUTE: &str = "/files";
pub static SETTINGS_ROUTE: &str = "/settings";
pub static UNLOCK_ROUTE: &str = "/";
pub static AUTH_ROUTE: &str = "/auth";

#[derive(Debug, Parser)]
#[clap(name = "")]
struct Args {
    #[clap(long)]
    path: Option<PathBuf>,
    #[clap(long)]
    experimental_node: bool,
    #[clap(long, default_value_t = false)]
    mock: bool,
}

fn copy_assets() {
    let themes_dest = STATIC_ARGS.uplink_path.join("themes");
    let themes_src = Path::new("ui").join("extra").join("themes");

    match create_all(themes_dest.clone(), false) {
        Ok(_) => {
            let mut options = CopyOptions::new();
            options.skip_exist = true;
            options.copy_inside = true;

            if let Err(error) = copy(themes_src, themes_dest, &options) {
                log::error!("Error on copy themes {error}");
            }
        }
        Err(error) => log::error!("Error on create themes folder: {error}"),
    };
}

fn main() {
    // Initializes the cache dir if needed
    std::fs::create_dir_all(STATIC_ARGS.uplink_path.clone())
        .expect("Error creating Uplink directory");
    std::fs::create_dir_all(STATIC_ARGS.warp_path.clone()).expect("Error creating Warp directory");
    copy_assets();

    let mut main_menu = Menu::new();
    let mut app_menu = Menu::new();
    let mut edit_menu = Menu::new();
    let mut window_menu = Menu::new();

    app_menu.add_native_item(MenuItem::About(
        String::from("Uplink"),
        AboutMetadata::default(),
    ));
    app_menu.add_native_item(MenuItem::Quit);
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

    let title = get_local_text("uplink");

    #[allow(unused_mut)]
    let mut window = WindowBuilder::new()
        .with_title(title)
        .with_resizable(true)
        .with_inner_size(LogicalSize::new(950.0, 600.0))
        .with_min_inner_size(LogicalSize::new(300.0, 500.0));

    #[cfg(target_os = "macos")]
    {
        use dioxus_desktop::tao::platform::macos::WindowBuilderExtMacOS;

        window = window
            .with_has_shadow(true)
            .with_title_hidden(true)
            .with_transparent(true)
            .with_fullsize_content_view(true)
            .with_titlebar_transparent(true);
        // .with_movable_by_window_background(true)
    }

    let config = Config::default();

    dioxus_desktop::launch_cfg(
        bootstrap,
        config
            .with_window(window.with_menu(main_menu))
            .with_custom_index(
                r#"
    <!doctype html>
    <html>
    <body style="background-color:rgba(0,0,0,0);"><div id="main"></div></body>
    </html>"#
                    .to_string(),
            ),
    )
}

fn bootstrap(cx: Scope) -> Element {
    //println!("rendering bootstrap");

    // warp_runner must be started from within a tokio reactor
    let mut warp_runner = warp_runner::WarpRunner::init();
    warp_runner.run(WARP_CHANNELS.0.clone(), WARP_CMD_CH.1.clone());

    let mut state = if STATIC_ARGS.use_mock {
        State::mock()
    } else {
        State::load().expect("failed to load state")
    };

    // todo: delete this. it is just an examle
    let desktop = use_window(cx);
    if Configuration::load_or_default().general.enable_overlay {
        let overlay_test = VirtualDom::new(OverlayDom);
        let window = desktop.new_window(overlay_test, make_config());
        state.ui.overlays.push(window);
    }

    use_shared_state_provider(cx, || state);
    cx.render(rsx!(crate::app {}))
}

fn app(cx: Scope) -> Element {
    println!("rendering app");
    let desktop = use_window(cx);
    let state = use_shared_state::<State>(cx)?;
    let toggle = use_state(cx, || false);
    let warp_event_rx = use_state(cx, || WARP_CHANNELS.1.clone());

    let inner = state.inner();
    use_future(cx, (), |_| {
        to_owned![toggle];
        async move {
            //println!("starting toast use_future");
            loop {
                sleep(Duration::from_secs(1)).await;
                {
                    let state = inner.borrow();
                    if !state.read().has_toasts() {
                        continue;
                    }
                    if state.write().decrement_toasts() {
                        let flag = *toggle.get();
                        toggle.set(!flag);
                    }
                }
            }
        }
    });

    let inner = state.inner();
    use_future(cx, (), |_| {
        to_owned![toggle, warp_event_rx];
        async move {
            //println!("starting warp_runner use_future");
            // it should be sufficient to lock once at the start of the use_future. this is the only place the channel should be read from. in the off change that
            // the future restarts (it shouldn't), the lock should be dropped and this wouldn't block.
            let mut ch = warp_event_rx.lock().await;
            while let Some(evt) = ch.recv().await {
                println!("warp_runner got event");
                if warp_runner::handle_event(inner.clone(), evt).await {
                    let flag = *toggle.current();
                    toggle.set(!flag);
                }
            }
        }
    });

    let user_lang_saved = state.read().settings.language.clone();
    change_language(user_lang_saved);

    let pre_release_text = get_local_text("uplink.pre-release");

    let theme = state
        .read()
        .ui
        .theme
        .as_ref()
        .map(|theme| theme.styles.clone())
        .unwrap_or_default();

    let pending_friends = state.read().friends.incoming_requests.len();
    cx.render(rsx! (
        style { "{UIKIT_STYLES} {APP_STYLE} {theme}" },
        div {
            class: "drag-handle",
            onmousedown: move |_| desktop.drag(),
        },
        div {
            id: "app-wrap",
            get_toasts(cx, &state.read()),
            get_call_dialog(cx),
            div {
                id: "pre-release",
                aria_label: "pre-release",
                onmousedown: move |_| { desktop.drag(); },
                IconElement {
                    icon: Icon::Beaker,
                },
                p {
                    "{pre_release_text}",
                }
            },
            //state.read().ui.popout_player.then(|| rsx!(
           //     PopoutPlayer {}
           // )),
           get_router(cx, pending_friends)
        }
    ))
}

fn get_toasts<'a>(cx: Scope<'a>, state: &State) -> Element<'a> {
    cx.render(rsx!(state.ui.toast_notifications.iter().map(
        |(id, toast)| {
            rsx!(Toast {
                id: *id,
                with_title: toast.title.clone(),
                with_content: toast.content.clone(),
                icon: toast.icon.unwrap_or(Icon::InformationCircle),
                appearance: Appearance::Secondary,
            },)
        }
    )))
}

fn get_call_dialog(_cx: Scope) -> Element {
    // CallDialog {
    //     caller: cx.render(rsx!(UserImage {
    //         platform: Platform::Mobile,
    //         status: Status::Online
    //     })),
    //     callee: cx.render(rsx!(UserImage {
    //         platform: Platform::Mobile,
    //         status: Status::Online
    //     })),
    //     description: "Call Description".into(),
    //     // with_accept_btn: cx.render(rsx! (
    //     //     Button {
    //     //         icon: Icon::Phone,
    //     //         appearance: Appearance::Success,
    //     //     }
    //     // )),
    //     with_deny_btn: cx.render(rsx! (
    //         Button {
    //             icon: Icon::PhoneXMark,
    //             appearance: Appearance::Danger,
    //             text: "End".into(),
    //         }
    //     )),
    // }
    None
}

fn get_router(cx: Scope, pending_friends: usize) -> Element {
    let chat_route = UIRoute {
        to: CHAT_ROUTE,
        name: get_local_text("uplink.chats"),
        icon: Icon::ChatBubbleBottomCenterText,
        ..UIRoute::default()
    };
    let settings_route = UIRoute {
        to: SETTINGS_ROUTE,
        name: get_local_text("settings.settings"),
        icon: Icon::Cog,
        ..UIRoute::default()
    };
    let friends_route = UIRoute {
        to: FRIENDS_ROUTE,
        name: get_local_text("friends.friends"),
        icon: Icon::Users,
        with_badge: if pending_friends > 0 {
            Some(pending_friends.to_string())
        } else {
            None
        },
        loading: None,
    };
    let files_route = UIRoute {
        to: FILES_ROUTE,
        name: get_local_text("files.files"),
        icon: Icon::Folder,
        ..UIRoute::default()
    };
    let routes = vec![
        chat_route.clone(),
        files_route.clone(),
        friends_route.clone(),
        settings_route.clone(),
    ];

    cx.render(rsx!(
            Router {
                Route {
                    to: CHAT_ROUTE,
                    ChatLayout {
                        route_info: RouteInfo {
                            routes: routes.clone(),
                            active: chat_route.clone(),
                        }
                    }
                },
                Route {
                    to: SETTINGS_ROUTE,
                    SettingsLayout {
                        route_info: RouteInfo {
                            routes: routes.clone(),
                            active: settings_route.clone(),
                        }
                    }
                },
                Route {
                    to: FRIENDS_ROUTE,
                    FriendsLayout {
                        route_info: RouteInfo {
                            routes: routes.clone(),
                            active: friends_route.clone(),
                        }
                    }
                },
                Route {
                    to: FILES_ROUTE,
                    FilesLayout {
                        route_info: RouteInfo {
                            routes: routes.clone(),
                            active: files_route,
                        }
                    }
                },
                Route {
                    to: UNLOCK_ROUTE,
                    UnlockLayout {}
                }
                Route {
                    to: AUTH_ROUTE,
                    AuthLayout {}
                }
        }
    ))
}
