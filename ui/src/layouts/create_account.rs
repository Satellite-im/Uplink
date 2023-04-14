use common::icons::outline::Shape as Icon;
use common::language::get_local_text;
use common::state::configuration::Configuration;
use common::{
    sounds,
    warp_runner::{MultiPassCmd, WarpCmd},
    WARP_CMD_CH,
};
use dioxus::prelude::*;
use futures::channel::oneshot;
use futures::StreamExt;
use kit::elements::{
    button::Button,
    input::{Input, Options, Validation},
};
use warp::logging::tracing::log;
use warp::multipass;

use crate::AuthPages;

pub const MIN_USERNAME_LEN: i32 = 4;
pub const MAX_USERNAME_LEN: i32 = 32;

#[inline_props]
#[allow(non_snake_case)]
pub fn CreateAccountLayout(cx: Scope, page: UseState<AuthPages>, pin: UseRef<String>) -> Element {
    log::trace!("rendering create account layout");
    let username = use_state(cx, String::new);
    //let error = use_state(cx, String::new);
    let button_disabled = use_state(cx, || true);

    let username_validation = Validation {
        // The input should have a maximum length of 32
        max_length: Some(MAX_USERNAME_LEN),
        // The input should have a minimum length of 4
        min_length: Some(MIN_USERNAME_LEN),
        // The input should only contain alphanumeric characters
        alpha_numeric_only: true,
        // The input should not contain any whitespace
        no_whitespace: true,
        // The input component validation is shared - if you need to allow just colons in, set this to true
        ignore_colons: false,
        // The input should allow any special characters
        // if you need special chars, select action to allow or block and pass a vec! with each char necessary, mainly if alpha_numeric_only is true
        special_chars: None,
    };

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<(String, String)>| {
        to_owned![page];
        async move {
            let config = Configuration::load_or_default();
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some((username, passphrase)) = rx.next().await {
                let (tx, rx) =
                    oneshot::channel::<Result<multipass::identity::Identity, warp::error::Error>>();

                if let Err(e) = warp_cmd_tx.send(WarpCmd::MultiPass(MultiPassCmd::CreateIdentity {
                    username,
                    passphrase,
                    rsp: tx,
                })) {
                    log::error!("failed to send warp command: {}", e);
                    continue;
                }

                let res = rx.await.expect("failed to get response from warp_runner");

                match res {
                    Ok(ident) => {
                        if config.audiovideo.interface_sounds {
                            sounds::Play(sounds::Sounds::On);
                        }

                        page.set(AuthPages::Success(ident));
                    }
                    // todo: notify user
                    Err(e) => log::error!("create identity failed: {}", e),
                }
            }
        }
    });

    cx.render(rsx!(
        div {
            id: "unlock-layout",
            aria_label: "unlock-layout",
            Input {
                id: "username-input".to_owned(),
                focus: true,
                is_password: false,
                icon: Icon::Identification,
                aria_label: "username-input".into(),
                disable_onblur: true,
                disabled: false,
                placeholder: get_local_text("auth.enter-username"),
                options: Options {
                    with_validation: Some(username_validation),
                    with_clear_btn: true,
                    clear_on_submit: false,
                    ..Default::default()
                }
                onchange: |(val, is_valid): (String, bool)| {
                    let should_disable = !is_valid;
                    if *button_disabled.get() != should_disable {
                        button_disabled.set(should_disable);
                    }
                    username.set(val);
                }
                onreturn: move |_| {
                    if !*button_disabled.get() {
                        ch.send((username.get().to_string(), pin.read().to_string()));
                    }
                }
            },
            Button {
                text:  get_local_text("unlock.create-account"),
                aria_label: "create-account-button".into(),
                appearance: kit::elements::Appearance::Primary,
                icon: Icon::Check,
                disabled: *button_disabled.get(),
                onpress: move |_| {

                    ch.send((username.get().to_string(), pin.read().to_string()));
                }

            }
        }
    ))
}
