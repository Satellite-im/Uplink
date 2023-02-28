use common::{
    language::get_local_text, state::configuration::Configuration, warp_runner::TesseractCmd,
};
use dioxus::prelude::*;
use futures::channel::oneshot;
use futures::StreamExt;
use kit::elements::{
    button::Button,
    input::{Input, Options, Validation},
    label::Label,
};
use warp::logging::tracing::log;

use common::icons::outline::Shape as Icon;
use common::{
    sounds,
    warp_runner::{MultiPassCmd, WarpCmd},
    WARP_CMD_CH,
};

use crate::AuthPages;

// todo: go to the auth page if no account has been created
#[inline_props]
#[allow(non_snake_case)]
pub fn UnlockLayout(cx: Scope, page: UseState<AuthPages>, pin: UseRef<String>) -> Element {
    log::trace!("rendering unlock layout");
    let button_disabled = use_state(cx, || true);

    // todo: maybe use this later
    let password_failed = use_state(cx, || false);

    let account_exists = use_state(cx, || true);
    let ran_once = use_state(cx, || false);

    // this will be needed later
    use_future(cx, (), |_| {
        to_owned![account_exists, ran_once];
        async move {
            if *ran_once.current() {
                return;
            }
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            let (tx, rx) = oneshot::channel::<bool>();
            if let Err(e) =
                warp_cmd_tx.send(WarpCmd::Tesseract(TesseractCmd::AccountExists { rsp: tx }))
            {
                log::error!("failed to send warp command: {}", e);
                // returning true will prevent the account from being created
                return;
            }

            let exists = rx.await.unwrap_or(false);
            log::debug!("account_exists: {}", exists);
            account_exists.set(exists);
            ran_once.set(true);
        }
    });

    let ch = use_coroutine(cx, |mut rx| {
        to_owned![password_failed, page];
        async move {
            let config = Configuration::load_or_default();
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(password) = rx.next().await {
                let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();

                if let Err(e) = warp_cmd_tx.send(WarpCmd::MultiPass(MultiPassCmd::TryLogIn {
                    passphrase: password,
                    rsp: tx,
                })) {
                    log::error!("failed to send warp command: {}", e);
                    continue;
                }

                let res = rx.await.expect("failed to get response from warp_runner");

                match res {
                    Ok(_) => {
                        if config.audiovideo.interface_sounds {
                            sounds::Play(sounds::Sounds::On);
                        }
                        page.set(AuthPages::Success)
                    }
                    Err(err) => match err {
                        warp::error::Error::DecryptionError => {
                            // wrong password
                            password_failed.set(true);
                            log::warn!("decryption error");
                        }
                        _ => {
                            // unexpected
                            log::error!("LogIn failed: {}", err);
                        }
                    },
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
        // The input component validation is shared - if you need to allow just colons in, set this to true
        ignore_colons: false,
        // The input should allow any special characters
        // if you need special chars, select action to allow or block and pass a vec! with each char necessary, mainly if alpha_numeric_only is true
        special_chars: None,
    };

    let account_exists_bool = *account_exists.get();

    // todo: use password_failed to display an error message
    cx.render(rsx!(
        div {
            id: "unlock-layout",
            aria_label: "unlock-layout",
            div {
                class: "unlock-details",
                Label {
                    text: get_local_text("unlock.enter-pin")
                },
                Input {
                    id: "unlock-input".to_owned(),
                    focus: true,
                    is_password: true,
                    icon: Icon::Key,
                    aria_label: "pin-input".into(),
                    disabled: false,
                    placeholder: get_local_text("unlock.enter-pin"),
                    options: Options {
                        with_validation: Some(pin_validation),
                        with_clear_btn: true,
                        ..Default::default()
                    }
                    onchange: move |(val, password_success): (String, bool)| {
                        *pin.write_silent() = val.clone();
                        let password_fail = !password_success;
                        if *button_disabled.get() != password_fail {
                            button_disabled.set(password_fail);
                        }
                        if password_success {
                            ch.send(val)
                        }
                    }
                    onreturn: move |_| {
                        if !*button_disabled.get() && !account_exists_bool {
                            page.set(AuthPages::CreateAccount);
                        }
                    }
                },
                ran_once.get().then(|| {
                    cx.render(rsx!(
                        Button {
                            text: match account_exists_bool {
                                true => get_local_text("unlock.unlock-account"),
                                false => get_local_text("unlock.create-account"),
                            },
                            aria_label: "create-account-button".into(),
                            appearance: kit::elements::Appearance::Primary,
                            icon: Icon::Check,
                            disabled: *button_disabled.get() || account_exists_bool,
                            onpress: move |_| {
                                page.set(AuthPages::CreateAccount);
                            }
                        }
                    ))
                })
                span {
                    get_local_text("unlock.notice")
                }
            },

        }
    ))
}
