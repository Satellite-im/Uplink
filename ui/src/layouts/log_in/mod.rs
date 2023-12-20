mod create_account;
mod entry_point;
mod recover_account;

use dioxus::prelude::*;
use dioxus_desktop::{use_window, LogicalSize};
use kit::components::topbar_controls::TopbarControls;
use kit::STYLE as UIKIT_STYLES;
use warp::multipass;
pub const APP_STYLE: &str = include_str!("../../compiled_styles.css");

// serve as a sort of router while the user logs in]
#[allow(clippy::large_enum_variant)]
#[derive(PartialEq, Eq)]
pub enum AuthPages {
    EntryPoint,
    CreateOrRecover,
    CreateAccount,
    RecoverAccount,
    PickUsername,
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
                id: "lockscreen-controls",
                div {
                    class: "draggable-topbar",
                    onmousedown: move |_| { desktop.drag(); },
                },
                TopbarControls {},
            },

            match *page.current() {
                AuthPages::EntryPoint => rsx!(entry_point::Layout { page: page.clone(), pin: pin.clone() }),
                AuthPages::CreateAccount => rsx!(create_account::Layout { page: page.clone(), pin: pin.clone() }),
                _ => unreachable!("this view should disappear when an account is unlocked or created"),
            }
        }
    ))
}
