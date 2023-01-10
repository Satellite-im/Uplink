use dioxus::prelude::*;
use dioxus_desktop::{use_window, LogicalSize};
use dioxus_router::use_router;
use futures::channel::oneshot;
use futures::StreamExt;
use kit::{
    elements::{
        button::Button,
        input::{Input, Options, Validation},
    },
    icons::Icon,
};

use crate::{
    warp_runner::{commands::TesseractCmd, WarpCmd},
    AUTH_ROUTES, UPLINK_ROUTES, WARP_CMD_CH,
};

// todo: go to the auth page if no account has been created
#[allow(non_snake_case)]
pub fn UnlockLayout(cx: Scope) -> Element {
    let desktop = use_window(cx);
    desktop.set_inner_size(LogicalSize {
        width: 500.0,
        height: 300.0,
    });

    let password_failed: &UseRef<Option<bool>> = use_ref(cx, || None);
    let router = use_router(cx);

    let ch = use_coroutine(cx, |mut rx| {
        to_owned![password_failed, router];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(password) = rx.next().await {
                //println!("unlock got password input");
                let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();

                warp_cmd_tx
                    .send(WarpCmd::Tesseract(TesseractCmd::Unlock {
                        passphrase: password,
                        rsp: tx,
                    }))
                    .expect("UnlockLayout failed to send warp command");

                let res = rx.await.expect("failed to get response from warp_runner");

                //println!("got response from warp");
                match res {
                    Ok(_) => router.replace_route(UPLINK_ROUTES.chat, None, None),
                    Err(_) => password_failed.set(Some(true)),
                }
            }
        }
    });

    // Set up validation options for the input field
    let pin_validation = Validation {
        // The input should have a maximum length of 32
        max_length: Some(32),
        // The input should have a minimum length of 4
        min_length: Some(4),
        // The input should only contain alphanumeric characters
        alpha_numeric_only: false,
        // The input should not contain any whitespace
        no_whitespace: true,
    };

    // todo: use password_failed to display an error message
    cx.render(rsx!(
        div {
            id: "unlock-layout",
            aria_label: "unlock-layout",
            onmousedown: move |_| {
                desktop.drag();
            },
            get_prompt(cx),
            Input {
                is_password: true,
                icon: Icon::Key,
                aria_label: "pin-input".into(),
                disabled: false,
                placeholder: "enter pin".into(), //get_local_text("unlock.enter_pin"),
                options: Options {
                    with_validation: Some(pin_validation),
                    with_clear_btn: true,
                    ..Default::default()
                }
                onreturn: move |(val, _is_valid)| {
                    ch.send(val)
                }
            },
            Button {
                text: "create account".into(), // get_local_text("unlock.create_account"),
                aria_label: "create-account-button".into(),
                appearance: kit::elements::Appearance::Primary,
                icon: Icon::Check,
                onpress: move |_| {
                    router.replace_route(AUTH_ROUTES.create_account, None, None)
                }
            }
        }
    ))
}

fn get_prompt(cx: Scope) -> Element {
    cx.render(rsx!(
        p {
            class: "info",
            aria_label: "unlock-warning-paragraph",
            "warning: use a good password", //get_local_text("unlock.warning1")
            //"Your password is used to encrypt your data. It is never sent to any server. You should use a strong password that you don't use anywhere else."
            br {},
            span {
                aria_label: "unlock-warning-span",
                class: "warning",
                //"If you forget this password we cannot help you retrieve it."
                "warning: no password recovery", //get_local_text("unlock.warning2")
            }
        }
    ))
}
