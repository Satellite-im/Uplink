use common::{
    language::{get_local_text, get_local_text_args_builder},
    state::{configuration::Configuration, State},
    warp_runner::TesseractCmd,
    STATIC_ARGS,
};
use dioxus::prelude::*;
use futures::channel::oneshot;
use futures::StreamExt;
use kit::elements::{
    button::Button,
    input::{Input, Options, Validation},
    label::LabelWithEllipsis,
};
use warp::{logging::tracing::log, multipass};

use common::icons::outline::Shape as Icon;
use common::{
    sounds,
    warp_runner::{MultiPassCmd, WarpCmd},
    WARP_CMD_CH,
};

use crate::AuthPages;

enum UnlockError {
    ValidationError,
    InvalidPin,
    Unknown,
}

impl UnlockError {
    fn as_str(&self) -> &'static str {
        match self {
            UnlockError::ValidationError => "Something is wrong with the pin you supplied.",
            UnlockError::InvalidPin => "Hmm, that pin didn't work.",
            UnlockError::Unknown => "An unknown error occurred.",
        }
    }
}

// todo: go to the auth page if no account has been created
#[inline_props]
#[allow(non_snake_case)]
pub fn UnlockLayout(cx: Scope, page: UseState<AuthPages>, pin: UseRef<String>) -> Element {
    log::trace!("rendering unlock layout");
    let validation_failure: &UseState<Option<UnlockError>> =
        use_state(cx, || Some(UnlockError::ValidationError)); // By default no pin is an invalid pin.

    let error: &UseState<Option<UnlockError>> = use_state(cx, || None);
    let shown_error = use_state(cx, || "");

    let account_exists: &UseState<Option<bool>> = use_state(cx, || None);
    let cmd_in_progress = use_state(cx, || false);

    let state = use_state(cx, State::load);

    // this will be needed later
    use_future(cx, (), |_| {
        to_owned![account_exists];
        async move {
            if account_exists.current().is_some() {
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
            account_exists.set(Some(exists));
        }
    });

    let ch = use_coroutine(cx, |mut rx| {
        to_owned![error, page, cmd_in_progress];
        async move {
            let config = Configuration::load_or_default();
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(password) = rx.next().await {
                let (tx, rx) =
                    oneshot::channel::<Result<multipass::identity::Identity, warp::error::Error>>();

                if let Err(e) = warp_cmd_tx.send(WarpCmd::MultiPass(MultiPassCmd::TryLogIn {
                    passphrase: password,
                    rsp: tx,
                })) {
                    log::error!("failed to send warp command: {}", e);
                    cmd_in_progress.set(false);
                    continue;
                }

                let res = rx.await.expect("failed to get response from warp_runner");

                match res {
                    Ok(ident) => {
                        if config.audiovideo.interface_sounds {
                            sounds::Play(sounds::Sounds::On);
                        }

                        page.set(AuthPages::Success(ident))
                    }
                    Err(err) => match err {
                        warp::error::Error::DecryptionError => {
                            // wrong password
                            error.set(Some(UnlockError::InvalidPin));
                            log::warn!("decryption error");
                        }
                        warp::error::Error::IdentityNotCreated => {
                            // this is supposed to fail.
                        }
                        _ => {
                            // unexpected
                            error.set(Some(UnlockError::Unknown));
                            log::error!("LogIn failed: {}", err);
                        }
                    },
                }
                cmd_in_progress.set(false);
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

    let loading = account_exists.current().is_none();

    let image_path = STATIC_ARGS
        .extras_path
        .join("images")
        .join("mascot")
        .join("idle_alt.png")
        .to_str()
        .map(|x| x.to_string())
        .unwrap_or_default();

    cx.render(rsx!(
        style {update_theme_colors(&state.current())},
        div {
            id: "unlock-layout",
            aria_label: "unlock-layout",
            if loading {
                rsx!(
                    div {
                        class: "skeletal-bars",
                        div {
                            class: "skeletal skeletal-bar",
                        },
                    }
                )
            } else {
                rsx! (
                    img {
                        class: "idle",
                        src: "{image_path}"
                    },
                    Input {
                        id: "unlock-input".to_owned(),
                        focus: true,
                        is_password: true,
                        icon: Icon::Key,
                        disable_onblur: !account_exists.current().unwrap_or(true),
                        aria_label: "pin-input".into(),
                        disabled: loading,
                        placeholder: get_local_text("unlock.enter-pin"),
                        options: Options {
                            with_validation: Some(pin_validation),
                            with_clear_btn: true,
                            with_label: if STATIC_ARGS.cache_path.exists()
                            {Some(get_welcome_message(&state.current()))}
                            else
                                {Some(get_local_text("unlock.create-password"))}, // TODO: Implement this.
                            ellipsis_on_label: Some(LabelWithEllipsis {
                                apply_ellipsis: true,
                                padding_rigth_for_ellipsis: 105,
                            }),
                            ..Default::default()
                        }
                        onchange: move |(val, validation_passed): (String, bool)| {
                            *pin.write_silent() = val.clone();
                            // Reset the error when the person changes the pin
                            if !shown_error.get().is_empty() {
                                shown_error.set("");
                            }
                            if validation_passed {
                                cmd_in_progress.set(true);
                                ch.send(val);
                                validation_failure.set(None);
                            } else {
                                validation_failure.set(Some(UnlockError::ValidationError));
                            }
                        }
                        onreturn: move |_| {
                            if let Some(validation_error) = validation_failure.get() {
                                shown_error.set(validation_error.as_str());
                            } else if let Some(e) = error.get() {
                                shown_error.set(e.as_str());
                            } else {
                                page.set(AuthPages::CreateAccount);
                            }
                        }
                    },
                    (!shown_error.get().is_empty()).then(|| rsx!(
                        span {
                            class: "error",
                            "{shown_error}"
                        }
                    )),
                    div {
                        class: "unlock-details",
                        span {
                            get_local_text("unlock.notice")
                        }
                    }
                    Button {
                            text: match account_exists.current().unwrap_or(true) {
                                true => get_local_text("unlock.unlock-account"),
                                false => get_local_text("unlock.create-account"),
                            },
                            aria_label: "create-account-button".into(),
                            appearance: kit::elements::Appearance::Primary,
                            icon: Icon::Check,
                            disabled: validation_failure.current().is_some() || *cmd_in_progress.current(),
                            onpress: move |_| {
                                if let Some(validation_error) = validation_failure.get() {
                                    shown_error.set(validation_error.as_str());
                                } else if let Some(e) = error.get() {
                                    shown_error.set(e.as_str());
                                } else {
                                    page.set(AuthPages::CreateAccount);
                                }
                            }
                        }
                )
            }
        }
    ))
}

fn update_theme_colors(state: &State) -> String {
    match state.ui.theme.as_ref() {
        Some(theme) => theme.styles.clone(),
        None => String::new(),
    }
}

fn get_welcome_message(state: &State) -> String {
    let name = match state.ui.cached_username.as_ref() {
        Some(name) => name.clone(),
        None => String::from("UNKNOWN"),
    };

    get_local_text_args_builder("unlock.welcome", |m| {
        m.insert("name", name.into());
    })
}
