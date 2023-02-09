use dioxus::prelude::*;
use futures::channel::oneshot;
use futures::StreamExt;
use kit::{
    elements::{
        button::Button,
        input::{Input, Options, Validation},
    },
    icons::Icon,
};
use shared::language::get_local_text;
use warp::logging::tracing::log;

use crate::{
    config::Configuration,
    warp_runner::{MultiPassCmd, TesseractCmd, WarpCmd},
    AuthPages, STATIC_ARGS, WARP_CMD_CH,
};

// todo: go to the auth page if no account has been created
#[inline_props]
#[allow(non_snake_case)]
pub fn UnlockLayout(cx: Scope, page: UseState<AuthPages>, pin: UseRef<String>) -> Element {
    log::trace!("rendering unlock layout");
    let password_failed: &UseRef<Option<bool>> = use_ref(cx, || None);
    let no_account: &UseState<Option<bool>> = use_state(cx, || None);
    let button_disabled = use_state(cx, || true);

    let account_exists = use_future(cx, (), |_| async move {
        let warp_cmd_tx = WARP_CMD_CH.tx.clone();
        let (tx, rx) = oneshot::channel::<bool>();
        if let Err(e) = warp_cmd_tx.send(WarpCmd::Tesseract(TesseractCmd::KeyExists {
            key: STATIC_ARGS.tesseract_initialized_key.clone(),
            rsp: tx,
        })) {
            log::error!("failed to send warp command: {}", e);
            // returning true will prevent the account from being created
            return true;
        }

        let exists = rx.await.unwrap_or(false);
        log::debug!("account_exists: {}", exists);
        exists
    });
    let ch = use_coroutine(cx, |mut rx| {
        to_owned![password_failed, no_account, page];
        async move {
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
                        if Configuration::load_or_default().audiovideo.interface_sounds {
                            crate::utils::sounds::Play(crate::utils::sounds::Sounds::On);
                        }
                        page.set(AuthPages::Success)
                    }
                    Err(err) => match err {
                        warp::error::Error::MultiPassExtensionUnavailable => {
                            // need to create an account
                            no_account.set(Some(true));
                            log::warn!("multipass extension unavailable");
                        }
                        warp::error::Error::DecryptionError => {
                            // wrong password
                            no_account.set(Some(false));
                            password_failed.set(Some(true));
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
    };

    // todo: use password_failed to display an error message
    cx.render(rsx!(
        div {
            id: "unlock-layout",
            aria_label: "unlock-layout",
            p {
                class: "info",
                aria_label: "unlock-warning-paragraph",
                get_local_text("unlock.warning1")
                br {},
                span {
                    aria_label: "unlock-warning-span",
                    class: "warning",
                    get_local_text("unlock.warning2")
                }
            },
            Input {
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
                onchange: move |(val, is_valid): (String, bool)| {
                    *pin.write_silent() = val.clone();
                    let should_disable = !is_valid;
                    if *button_disabled.get() != should_disable {
                        button_disabled.set(should_disable);
                    }
                    if !should_disable {
                        ch.send(val)
                    }
                }
                onreturn: move |_| {
                    if !*button_disabled.get() {
                        page.set(AuthPages::CreateAccount);
                    }
                }
            },
            // want this to not render while account_exists is loading.
            // therefore, default it to true
            (!account_exists.value().unwrap_or(&true)).then(|| rsx!(
                Button {
                    text: get_local_text("unlock.create-account"),
                    aria_label: "create-account-button".into(),
                    appearance: kit::elements::Appearance::Primary,
                    icon: Icon::Check,
                    disabled: *button_disabled.get(),
                    onpress: move |_| {
                        page.set(AuthPages::CreateAccount);
                    }
                }
            ))
        }
    ))
}
