//#![deny(elided_lifetimes_in_paths)]

use clap::Parser;
use dioxus_desktop::tao::dpi::LogicalSize;
#[cfg(target_os = "macos")]
use dioxus_desktop::tao::platform::macos::WindowBuilderExtMacOS;
use dioxus_desktop::{tao, use_window};

use dioxus::prelude::*;
use dioxus_desktop::tao::menu::AboutMetadata;
use dioxus_desktop::Config;

use fs_extra::dir::*;
use kit::elements::Appearance;
use kit::icons::IconElement;
use kit::{components::nav::Route as UIRoute, icons::Icon};
use once_cell::sync::Lazy;
use state::State;
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;
use tao::menu::{MenuBar as Menu, MenuItem};
use tao::window::WindowBuilder;
use tokio::sync::Mutex;
use tokio::time::{sleep, Duration};
use warp::logging::tracing::log;

use crate::components::media::popout_player::PopoutPlayer;
use crate::components::toast::Toast;
use crate::layouts::files::FilesLayout;
use crate::layouts::friends::FriendsLayout;
use crate::layouts::settings::SettingsLayout;
use crate::layouts::unlock::UnlockLayout;
use crate::warp_runner::{WarpCmdRx, WarpEventRx, WarpCmdTx, WarpEventTx, WarpEvent};
use crate::{components::chat::RouteInfo, layouts::chat::ChatLayout};
use dioxus_router::*;

use kit::STYLE as UIKIT_STYLES;
use utils::language::get_local_text;
pub const APP_STYLE: &str = include_str!("./compiled_styles.css");
use fermi::prelude::*;
pub mod components;
pub mod config;
pub mod layouts;
pub mod state;
pub mod testing;
pub mod utils;
mod warp_runner;

use fluent_templates::static_loader;

pub static STATE: AtomRef<State> = |_| State::load().unwrap();

static_loader! {
    static LOCALES = {
        locales: "./locales",
        fallback_language: "en-US",
        // Removes unicode isolating marks around arguments, you typically
        // should only set to false when testing.
        customise: |bundle| bundle.set_use_isolating(false),
    };
}

// allows the UI to receive events to Warp
// pretty sure the rx channel needs to be in a mutex in order for it to be a static mutable variable
pub static WARP_CHANNELS: Lazy<(WarpEventTx, WarpEventRx)> = Lazy::new(|| {
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    (tx, Arc::new(Mutex::new(rx)))
});

// allows the UI to send commands to Warp
pub static WARP_CMD_CH: Lazy<(WarpCmdTx, WarpCmdRx)> = Lazy::new(|| {
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    (tx, Arc::new(Mutex::new(rx)))
});

pub static DEFAULT_PATH: Lazy<PathBuf> = Lazy::new(|| match Opt::parse().path {
    Some(path) => path,
    _ => dirs::home_dir().unwrap_or_default().join(".warp"),
});

#[derive(Debug, Parser)]
#[clap(name = "")]
struct Opt {
    #[clap(long)]
    path: Option<PathBuf>,
    #[clap(long)]
    experimental_node: bool,
}

fn copy_assets() {
    let cache_path = dirs::home_dir().unwrap_or_default().join(".uplink/");

    match create_all(cache_path.join("themes"), false) {
        Ok(_) => {
            let mut options = CopyOptions::new();
            options.skip_exist = true;
            options.copy_inside = true;

            if let Err(error) = copy("ui/extra/themes", cache_path, &options) {
                log::error!("Error on copy themes {error}");
            }
        }
        Err(error) => log::error!("Error on create themes folder: {error}"),
    };
}

fn main() {
    copy_assets();

    // Initalized the cache dir if needed
    let cache_path = dirs::home_dir()
        .unwrap_or_default()
        .join(".uplink/")
        .into_os_string()
        .into_string()
        .unwrap_or_default();

    let _ = fs::create_dir_all(cache_path);

    let mut main_menu = Menu::new();
    let mut app_menu = Menu::new();
    let mut edit_menu = Menu::new();
    let mut window_menu = Menu::new();

    app_menu.add_native_item(MenuItem::Quit);
    app_menu.add_native_item(MenuItem::About(
        String::from("Uplink"),
        AboutMetadata::default(),
    ));
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
        window = window
            .with_has_shadow(true)
            .with_title_hidden(true)
            .with_transparent(true)
            .with_fullsize_content_view(true)
            .with_titlebar_transparent(true)
        // .with_movable_by_window_background(true)
    }
    let config = Config::default();

    dioxus_desktop::launch_cfg(bootstrap, config.with_window(window.with_menu(main_menu)))
}

fn bootstrap(cx: Scope) -> Element {
    //println!("rendering bootstrap");
    let mut warp_runner = warp_runner::WarpRunner::init();
    warp_runner.run(WARP_CHANNELS.0.clone(), WARP_CMD_CH.1.clone());

    let state = match State::load() {
        Ok(s) => s,
        Err(_) => State::default(),
    };

    //use_init_atom_root(cx);
    use_shared_state_provider(cx, || state);

    let state = use_shared_state::<State>(cx)?;
    let toggle = use_state(cx, || false);
    let warp_rx = use_state(cx, || WARP_CHANNELS.1.clone());

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
                        let flag = *toggle.current();
                        toggle.set(!flag);
                    }
                }
            }
        }
    });

    let inner = state.inner();
    use_future(cx, (), |_| {
        to_owned![toggle, warp_rx];
        async move {
            //println!("starting warp_runner use_future");
            // it should be sufficient to lock once at the start of the use_future. this is the only place the channel should be read from. in the off change that
            // the future restarts (it shouldn't), the lock should be dropped and this wouldn't block.
            let mut ch = warp_rx.lock().await;
            while let Some(evt) = ch.recv().await {
                if warp_runner::handle_event(inner.clone(), evt).await {
                    let flag = *toggle.current();
                    toggle.set(!flag);
                }
            }
        }
    });

    let user_lang_saved = state.read().settings.language.clone();
    utils::language::change_language(user_lang_saved);

    let pending_friends = state.read().friends.incoming_requests.len();

    let chat_route = UIRoute {
        to: "/",
        name: get_local_text("uplink.chats"),
        icon: Icon::ChatBubbleBottomCenterText,
        ..UIRoute::default()
    };
    let settings_route = UIRoute {
        to: "/settings",
        name: get_local_text("settings.settings"),
        icon: Icon::Cog,
        ..UIRoute::default()
    };
    let friends_route = UIRoute {
        to: "/friends",
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
        to: "/files",
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

    let pre_release_text = get_local_text("uplink.pre-release");

    let desktop = use_window(cx);

    let theme = match &state.read().ui.theme {
        Some(theme) => theme.styles.to_owned(),
        None => String::from(""),
    };

    cx.render(rsx! (
        style { "{UIKIT_STYLES} {APP_STYLE} {theme}" },
        div {
            id: "app-wrap",
            state.read().ui.toast_notifications.iter().map(|(id, toast)| {
                rsx! (
                    Toast {
                        id: *id,
                        with_title: toast.title.clone(),
                        with_content: toast.content.clone(),
                        icon: toast.icon.unwrap_or(Icon::InformationCircle),
                        appearance: Appearance::Secondary,
                    },
                )
            }),
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
            // },
            div {
                id: "pre-release",
                onmousedown: move |_| { desktop.drag(); },
                IconElement {
                    icon: Icon::Beaker,
                },
                p {
                    "{pre_release_text}",
                }
            },
            state.read().ui.popout_player.then(|| rsx!(
                PopoutPlayer {}
            )),
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
                            routes: routes.clone(),
                            active: friends_route.clone(),
                        }
                    }
                },
                Route {
                    to: "/files",
                    FilesLayout {
                        route_info: RouteInfo {
                            routes: routes.clone(),
                            active: files_route.clone(),
                        }
                    }
                },
                Route {
                    to: "pre/unlock",
                    UnlockLayout {

                    }
                }
            }
        }
    ))
}
