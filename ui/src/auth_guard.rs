use dioxus::prelude::*;
use dioxus_desktop::{use_window, LogicalSize};
use kit::components::topbar_controls::Topbar_Controls;
use kit::STYLE as UIKIT_STYLES;
use warp::multipass;
pub const APP_STYLE: &str = include_str!("./compiled_styles.css");

use crate::layouts::{create_account::CreateAccountLayout, unlock::UnlockLayout};

// serve as a sort of router while the user logs in]
#[allow(clippy::large_enum_variant)]
#[derive(PartialEq, Eq)]
pub enum AuthPages {
    Unlock,
    CreateAccount,
    Success(multipass::identity::Identity),
}

/// Guard the app's router with the login flow
#[component]
pub fn AuthGuard(cx: Scope, page: UseState<AuthPages>) -> Element {
    log::trace!("rendering auth guard");

    let pin = use_ref(cx, String::new);
    let desktop = use_window(cx);
    let theme = "";

    // make the window smaller while the user authenticates
    let window = use_window(cx);

    if !matches!(&*page.current(), AuthPages::Success(_)) {
        window.set_inner_size(LogicalSize {
            width: 500.0,
            height: 350.0,
        });
    }

    cx.render(rsx! (
        style { "{UIKIT_STYLES} {APP_STYLE} {theme}" },
        div {
            id: "app-wrap",
            div {
                class: "titlebar disable-select",
                id: if cfg!(target_os = "macos") {""}  else {"lockscreen-controls"},
                onmousedown: move |_| { desktop.drag(); },
                Topbar_Controls {},
            },

            match *page.current() {
                AuthPages::Unlock => rsx!(UnlockLayout { page: page.clone(), pin: pin.clone() }),
                AuthPages::CreateAccount => rsx!(CreateAccountLayout { page: page.clone(), pin: pin.clone() }),
                _ => unreachable!("this view should disappear when an account is unlocked or created"),
            }
        }
    ))
}
