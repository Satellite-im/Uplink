use common::{
    icons,
    language::get_local_text,
    state::State,
    warp_runner::{MultiPassCmd, WarpCmd},
    WARP_CMD_CH,
};
use dioxus::prelude::*;
use dioxus_desktop::{use_window, LogicalSize};
use futures::{channel::oneshot, StreamExt};
use kit::elements::{button::Button, input, label::Label, Appearance};

use crate::get_app_style;

use super::AuthPages;

struct Cmd {
    seed_words: String,
    passphrase: String,
}

// styles for this layout are in layouts/style.scss
#[component]
pub fn Layout(cx: Scope, pin: UseRef<String>, page: UseState<AuthPages>) -> Element {
    let state = use_ref(cx, State::load);
    let loading = use_state(cx, || false);
    let input = use_ref(cx, String::new);

    let window = use_window(cx);

    if !matches!(&*page.current(), AuthPages::Success(_)) {
        window.set_inner_size(LogicalSize {
            width: 500.0,
            height: 260.0,
        });
    }
    // todo: show toasts to inform user of errors.
    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<Cmd>| {
        to_owned![loading, page];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(Cmd {
                seed_words,
                passphrase,
            }) = rx.next().await
            {
                let (tx, rx) = oneshot::channel();

                if let Err(e) =
                    warp_cmd_tx.send(WarpCmd::MultiPass(MultiPassCmd::RecoverIdentity {
                        passphrase,
                        seed_words,
                        rsp: tx,
                    }))
                {
                    log::error!("failed to send multipass cmd: {e}");
                    continue;
                }

                let rsp = match rx.await {
                    Ok(r) => r,
                    Err(e) => {
                        log::error!("warp runner cmd cancelled: {e}");
                        continue;
                    }
                };

                match rsp {
                    Ok(ident) => {
                        page.set(AuthPages::Success(ident));
                    }
                    Err(e) => {
                        loading.set(false);
                        log::error!("warp runner cmd cancelled: {e}");
                        continue;
                    }
                };
            }
        }
    });

    cx.render(rsx!(
        style {get_app_style(&state.read())},
        div {
            id: "enter-seed-words-layout",
            aria_label: "enter-seed-words-layout",
            Label {
                aria_label: "enter-seed-words".into(),
                text: get_local_text("enter-seed-words")
            },
            div {
                class: "instructions",
                get_local_text("enter-seed-words.instructions")
            },
            input::Input {
                placeholder: get_local_text("enter-seed-words.placeholder"),
                onchange: move |(x, is_valid)| {
                    if is_valid {
                        *input.write_silent() = x;
                    }
                }
            },
            div {
                class: "button-container",
                // todo: add 12 separate input boxes per figma
                Button {
                    aria_label: "back-button".into(),
                    text: get_local_text("uplink.go-back"),
                    icon: icons::outline::Shape::ChevronLeft,
                    onpress: move |_| page.set(AuthPages::CreateOrRecover),
                    appearance: Appearance::Secondary
                },
                Button {
                    text: get_local_text("enter-seed-words.submit"),
                    disabled: *loading.get(),
                    onpress: move |_| {
                        loading.set(true);
                        ch.send(Cmd {
                            seed_words: input.read().clone(),
                            passphrase: pin.read().clone()
                        });
                    }
                }
            }
        }
    ))
}
