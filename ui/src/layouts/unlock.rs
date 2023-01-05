use dioxus::prelude::*;
use dioxus_desktop::{use_window, LogicalSize};
use dioxus_router::use_router;
use futures::StreamExt;
use kit::{
    elements::{
        button::Button,
        input::{Input, Options, Validation},
        label::Label,
    },
    icons::Icon,
};
use tokio::sync::oneshot;

use crate::{
    state::State,
    warp_runner::{commands::TesseractCmd, WarpCmd},
    CHAT_ROUTE, WARP_CMD_CH,
};

#[allow(non_snake_case)]
pub fn UnlockLayout(cx: Scope) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let warp_cmd_tx = WARP_CMD_CH.0.clone();
    // true if password succeeded
    let password_failed: &UseRef<Option<bool>> = use_ref(cx, || None);
    let router = use_router(cx);

    let ch = use_coroutine(cx, |mut rx| {
        to_owned![warp_cmd_tx, password_failed, router];
        async move {
            while let Some(password) = rx.next().await {
                //println!("got password input");
                let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();
                warp_cmd_tx
                    .send(WarpCmd::Tesseract(TesseractCmd::Unlock {
                        passphrase: password,
                        rsp: tx,
                    }))
                    .expect("UnlockLayout failed to send warp command");

                let res = rx
                    .blocking_recv()
                    .expect("failed to get response from warp_runner");

                //println!("got response from warp");
                match res {
                    Ok(_) => router.replace_route(CHAT_ROUTE, None, None),
                    Err(_) => password_failed.set(Some(true)),
                }
            }
        }
    });

    // Set up validation options for the input field
    let validation_options = Validation {
        // The input should have a maximum length of 32
        max_length: Some(32),
        // The input should have a minimum length of 4
        min_length: Some(4),
        // The input should only contain alphanumeric characters
        alpha_numeric_only: false,
        // The input should not contain any whitespace
        no_whitespace: true,
    };

    let disabled = use_state(cx, || false);
    let desktop = use_window(cx);
    desktop.set_inner_size(LogicalSize {
        width: 500.0,
        height: 300.0,
    });

    cx.render(rsx!(
        div {
            id: "unlock-layout",
            onmousedown: move |_| {
                desktop.drag();
            },
            get_prompt(cx, state.read().account.tesseract_initialized, password_failed.read().unwrap_or(false)),
            p {
                class: "info",
                "Your password is used to encrypt your data. It is never sent to any server. You should use a strong password that you don't use anywhere else."
                br {},
                span {
                    class: "warning",
                    "If you forget this password we cannot help you retrieve it."
                }
            },
            Input {
                is_password: true,
                icon: Icon::Key,
                disabled: **disabled,
                placeholder: "Enter Password".into(),
                options: Options {
                    with_validation: Some(validation_options),
                    with_clear_btn: true,
                    ..Default::default()
                }
                onreturn: move |val| {
                    ch.send(val)
                }
            },
            Button {
                text: "Create Account".into(),
                appearance: kit::elements::Appearance::Primary,
                icon: Icon::Check,
                onpress: move |_| {
                    disabled.set(true);
                }
            }
        }
    ))
}

// todo: translate
// todo: better reaction when password failed. perhaps a toast?
fn get_prompt(cx: Scope, tesseract_available: bool, password_failed: bool) -> Element {
    if tesseract_available {
        if password_failed {
            cx.render(rsx!(Label {
                text: "Invalid Password".into()
            }))
        } else {
            cx.render(rsx!(Label {
                text: "Enter your password".into()
            }))
        }
    } else {
        assert!(!password_failed);
        cx.render(rsx!(Label {
            text: "Create a password".into()
        }))
    }
}
