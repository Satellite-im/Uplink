//#![deny(elided_lifetimes_in_paths)]

use clap::Parser;
use config::Configuration;
use dioxus::prelude::*;
use dioxus_desktop::tao::dpi::LogicalSize;
use dioxus_desktop::tao::menu::AboutMetadata;
use dioxus_desktop::Config;
use dioxus_desktop::{tao, use_window};
use fs_extra::dir::*;
use futures::channel::oneshot;
use kit::elements::Appearance;
use kit::elements::button::Button;
use kit::icons::IconElement;
use kit::{components::nav::Route as UIRoute, icons::Icon};
use overlay::{make_config, OverlayDom};
use shared::language::{change_language, get_local_text};
use state::State;
use std::path::{Path, PathBuf};

use std::sync::Arc;
use tao::menu::{MenuBar as Menu, MenuItem};
use tao::window::WindowBuilder;
use tokio::sync::Mutex;
use tokio::time::{sleep, Duration};
use warp::logging::tracing::log;

use crate::components::toast::Toast;
use crate::layouts::create_account::CreateAccountLayout;
use crate::layouts::files::FilesLayout;
use crate::layouts::friends::FriendsLayout;
use crate::layouts::settings::SettingsLayout;
use crate::layouts::unlock::UnlockLayout;
use crate::state::Action;
use crate::state::friends;
use crate::state::ui::WindowMeta;
use crate::warp_runner::commands::MultiPassCmd;
use crate::warp_runner::{WarpCmd, WarpCmdChannels, WarpEventChannels};
use crate::window_manager::WindowManagerCmdChannels;
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
mod window_manager;

#[macro_use]
extern crate lazy_static;

#[derive(Debug)]
pub struct StaticArgs {
    pub uplink_path: PathBuf,
    pub cache_path: PathBuf,
    pub config_path: PathBuf,
    pub warp_path: PathBuf,
    pub no_mock: bool,
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
            cache_path: uplink_path.join("state.json"),
            config_path: uplink_path.join("Config.json"),
            warp_path: uplink_path.join("warp"),
            no_mock: args.no_mock,
        }
    };

    // allows the UI to send commands to Warp
    pub static ref WARP_CMD_CH: WarpCmdChannels = {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        WarpCmdChannels {
            tx,
            rx:  Arc::new(Mutex::new(rx))
        }
    };

    // allows the UI to receive events to Warp
    // pretty sure the rx channel needs to be in a mutex in order for it to be a static mutable variable
    pub static ref WARP_EVENT_CH: WarpEventChannels =  {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        WarpEventChannels {
            tx,
            rx:  Arc::new(Mutex::new(rx))
        }
    };

    // used to close the popout player, among other things
    pub static ref WINDOW_CMD_CH: WindowManagerCmdChannels = {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        WindowManagerCmdChannels {
            tx,
            rx:  Arc::new(Mutex::new(rx))
        }
    };
}

pub struct UplinkRoutes<'a> {
    pub chat: &'a str,
    pub friends: &'a str,
    pub files: &'a str,
    pub settings: &'a str,
}

pub static UPLINK_ROUTES: UplinkRoutes = UplinkRoutes {
    chat: "/",
    friends: "/friends",
    files: "/files",
    settings: "/settings",
};

// serve as a sort of router while the user logs in
#[derive(PartialEq, Eq)]
pub enum AuthPages {
    Unlock,
    CreateAccount,
    Success,
}

#[derive(Debug, Parser)]
#[clap(name = "")]
struct Args {
    #[clap(long)]
    path: Option<PathBuf>,
    #[clap(long)]
    experimental_node: bool,
    // todo: when the app is mature, default mock to false
    // there's no way to set --flag=true so for make the flag mean false
    #[clap(long, default_value_t = false)]
    no_mock: bool,
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

// start warp_runner and ensure the user is logged in
fn bootstrap(cx: Scope) -> Element {
    //println!("rendering bootstrap");

    // warp_runner must be started from within a tokio reactor
    let mut warp_runner = warp_runner::WarpRunner::init();
    warp_runner.run(WARP_EVENT_CH.tx.clone(), WARP_CMD_CH.rx.clone());

    // make the window smaller while the user authenticates
    let desktop = use_window(cx);
    desktop.set_inner_size(LogicalSize {
        width: 500.0,
        height: 300.0,
    });
    cx.render(rsx!(crate::auth_page_manager {}))
}

// Uplink's Router depends on State, which can't be loaded until the user logs in.
// don't see a way to replace the router
// so instead use a Prop to determine which page to render
// after the user logs in, app_bootstrap loads Uplink as normal.
fn auth_page_manager(cx: Scope) -> Element {
    let page = use_state(cx, || AuthPages::Unlock);
    let pin = use_ref(cx, String::new);
    cx.render(rsx!(match *page.current() {
        AuthPages::Success => rsx!(app_bootstrap {}),
        _ => rsx!(auth_wrapper {
            page: page.clone(),
            pin: pin.clone()
        }),
    }))
}

#[inline_props]
fn auth_wrapper(cx: Scope, page: UseState<AuthPages>, pin: UseRef<String>) -> Element {
    let desktop = use_window(cx);
    let theme = "";
    let pre_release_text = get_local_text("uplink.pre-release");
    cx.render(rsx! (
        style { "{UIKIT_STYLES} {APP_STYLE} {theme}" },
        div {
            class: "drag-handle",
            onmousedown: move |_| desktop.drag(),
        },
        div {
            id: "app-wrap",
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
            match *page.current() {
                AuthPages::Unlock => rsx!(UnlockLayout { page: page.clone(), pin: pin.clone() }),
                AuthPages::CreateAccount => rsx!(CreateAccountLayout { page: page.clone(), pin: pin.clone() }),
                _ => panic!("invalid page")
            }
        }
    ))
}

// called at the end of the auth flow
#[inline_props]
pub fn app_bootstrap(cx: Scope) -> Element {
    //println!("rendering app_bootstrap");
    let mut state = if STATIC_ARGS.no_mock {
        State::load().expect("failed to load state")
    } else {
        State::mock()
    };

    // set the window to the normal size.
    // todo: perhaps when the user resizes the window, store that in State, and load that here
    let desktop = use_window(cx);
    desktop.set_inner_size(LogicalSize::new(950.0, 600.0));

    // todo: delete this. it is just an example
    if Configuration::load_or_default().general.enable_overlay {
        let overlay_test = VirtualDom::new(OverlayDom);
        let window = desktop.new_window(overlay_test, make_config());
        state.ui.overlays.push(window);
    }

    // Update the window metadata now that we've created a window
    let window_meta = WindowMeta {
        focused: desktop.is_focused(),
        maximized: desktop.is_maximized(),
        minimized: desktop.is_minimized(),
        width: desktop.inner_size().width,
        height: desktop.inner_size().height,
        minimal_view: desktop.inner_size().width < 600,
    };
    state.ui.metadata = window_meta;

    use_shared_state_provider(cx, || state);

    cx.render(rsx!(crate::app {}))
}

fn app(cx: Scope) -> Element {
    //println!("rendering app");
    let desktop = use_window(cx);
    let state = use_shared_state::<State>(cx)?;
    let friends_init = use_ref(cx, || false);
    let needs_update = use_state(cx, || false);

    // yes, double render. sry.
    if *needs_update.get() {
        needs_update.set(false);
        state.write();
    }

    let inner = state.inner();
    use_future(cx, (), |_| {
        to_owned![needs_update];
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
                        needs_update.set(true);
                    }
                }
            }
        }
    });

    let inner = state.inner();
    use_future(cx, (), |_| {
        to_owned![needs_update];
        async move {
            let warp_event_rx = WARP_EVENT_CH.rx.clone();
            //println!("starting warp_runner use_future");
            // it should be sufficient to lock once at the start of the use_future. this is the only place the channel should be read from. in the off change that
            // the future restarts (it shouldn't), the lock should be dropped and this wouldn't block.
            let mut ch = warp_event_rx.lock().await;
            while let Some(evt) = ch.recv().await {
                //println!("got warp event");
                match inner.try_borrow_mut() {
                    Ok(state) => {
                        state.write().process_warp_event(evt);
                        needs_update.set(true);
                    }
                    Err(_e) => {
                        // todo: log error
                    }
                }
            }
        }
    });

    let inner = state.inner();
    use_future(cx, (), |_| {
        to_owned![needs_update, desktop];
        async move {
            let window_cmd_rx = WINDOW_CMD_CH.rx.clone();
            let mut ch = window_cmd_rx.lock().await;
            while let Some(cmd) = ch.recv().await {
                window_manager::handle_cmd(inner.clone(), cmd, desktop.clone()).await;
                needs_update.set(true);
            }
        }
    });

    // todo: this should be done before the app Element...make the app wait while this loads up
    let inner = state.inner();
    use_future(cx, (), |_| {
        to_owned![friends_init, needs_update];
        async move {
            if *friends_init.read() {
                return;
            }
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            let (tx, rx) = oneshot::channel::<Result<friends::Friends, warp::error::Error>>();
            warp_cmd_tx
                .send(WarpCmd::MultiPass(MultiPassCmd::InitializeFriends {
                    rsp: tx,
                }))
                .expect("main send warp command");

            let res = rx.await.expect("failed to get response from warp_runner");

            //println!("got response from warp");
            match res {
                Ok(friends) => match inner.try_borrow_mut() {
                    Ok(state) => {
                        state.write().friends = friends;
                        needs_update.set(true);
                    }
                    Err(_e) => {
                        // todo: log error
                    }
                },
                Err(_e) => {
                    todo!("handle error response");
                }
            }

            *friends_init.write_silent() = true;
            needs_update.set(true);
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
            id: "app-wrap",
            div {
                id: "titlebar",
                onmousedown: move |_| { desktop.drag(); },
                // TODO: Only display this if developer mode is enabled.
                Button {
                    icon: Icon::DevicePhoneMobile,
                    appearance: Appearance::Transparent,
                    onpress: move |_| {
                        desktop.set_inner_size(LogicalSize::new(300.0, 534.0));
                        let meta = state.read().ui.metadata.clone();
                        state.write().mutate(Action::SetMeta(WindowMeta {
                            width: 300,
                            height: 534,
                            minimal_view: true,
                            ..meta
                        }));
                    }
                },
                Button {
                    icon: Icon::DeviceTablet,
                    appearance: Appearance::Transparent,
                    onpress: move |_| {
                        desktop.set_inner_size(LogicalSize::new(600.0, 534.0));
                        let meta = state.read().ui.metadata.clone();
                        state.write().mutate(Action::SetMeta(WindowMeta {
                            width: 600,
                            height: 534,
                            minimal_view: false,
                            ..meta
                        }));
                    }
                },
                Button {
                    icon: Icon::ComputerDesktop,
                    appearance: Appearance::Transparent,
                    onpress: move |_| {
                        desktop.set_inner_size(LogicalSize::new(950.0, 600.0));
                        let meta = state.read().ui.metadata.clone();
                        state.write().mutate(Action::SetMeta(WindowMeta {
                            width: 950,
                            height: 600,
                            minimal_view: false,
                            ..meta
                        }));
                    }
                },
                Button {
                    icon: Icon::CommandLine,
                    appearance: Appearance::Transparent,
                    onpress: |_| {
                        desktop.devtool();
                    }
                }
            },
            get_toasts(cx, &state.read()),
            get_call_dialog(cx),
            div {
                id: "pre-release",
                aria_label: "pre-release",
                IconElement {
                    icon: Icon::Beaker,
                },
                p {
                    "{pre_release_text}",
                }
            },
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
        to: UPLINK_ROUTES.chat,
        name: get_local_text("uplink.chats"),
        icon: Icon::ChatBubbleBottomCenterText,
        ..UIRoute::default()
    };
    let settings_route = UIRoute {
        to: UPLINK_ROUTES.settings,
        name: get_local_text("settings.settings"),
        icon: Icon::Cog6Tooth,
        ..UIRoute::default()
    };
    let friends_route = UIRoute {
        to: UPLINK_ROUTES.friends,
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
        to: UPLINK_ROUTES.files,
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
                to: UPLINK_ROUTES.chat,
                ChatLayout {
                    route_info: RouteInfo {
                        routes: routes.clone(),
                        active: chat_route.clone(),
                    }
                }
            },
            Route {
                to: UPLINK_ROUTES.settings,
                SettingsLayout {
                    route_info: RouteInfo {
                        routes: routes.clone(),
                        active: settings_route.clone(),
                    }
                }
            },
            Route {
                to: UPLINK_ROUTES.friends,
                FriendsLayout {
                    route_info: RouteInfo {
                        routes: routes.clone(),
                        active: friends_route.clone(),
                    }
                }
            },
            Route {
                to: UPLINK_ROUTES.files,
                FilesLayout {
                    route_info: RouteInfo {
                        routes: routes.clone(),
                        active: files_route,
                    }
                }
            },
        }
    ))
}
