use common::{icons, language::get_local_text, state::State};
use dioxus::prelude::*;
use dioxus_desktop::{use_window, LogicalSize};
use kit::elements::{button::Button, label::Label, Appearance};

use crate::get_app_style;

use super::AuthPages;

// styles for this layout are in layouts/style.scss
#[component]
pub fn Layout(cx: Scope, page: UseState<AuthPages>, seed_words: UseRef<String>) -> Element {
    let state = use_ref(cx, State::load);
    let window = use_window(cx);

    if !matches!(&*page.current(), AuthPages::Success(_)) {
        window.set_inner_size(LogicalSize {
            width: 500.0,
            height: 460.0,
        });
    }

    let words = use_future(cx, (), |_| {
        to_owned![seed_words];
        async move {
            let mnemonic = warp::crypto::keypair::generate_mnemonic_phrase(
                warp::crypto::keypair::PhraseType::Standard,
            )
            .into_phrase();

            seed_words.set(mnemonic.clone());
            mnemonic
                .split_ascii_whitespace()
                .map(|x| x.to_string())
                .collect::<Vec<String>>()
        }
    });

    cx.render(rsx!(
        style {get_app_style(&state.read())},
        div {
            id: "copy-seed-words-layout",
            aria_label: "copy-seed-words-layout",
            div {
                class: "instructions-important",
                get_local_text("copy-seed-words.instructions")
            },
            Label {
                aria_label: "copy-seed-words".into(),
                text: get_local_text("copy-seed-words")
            },
            if let Some(words) = words.value() {
                rsx!{ SeedWords { page: page.clone(), words: words.clone() } }
            }
        }
    ))
}

#[component]
fn SeedWords(cx: Scope, page: UseState<AuthPages>, words: Vec<String>) -> Element {
    render! {
        div {
            class: "seed-words",
            words.chunks_exact(2).enumerate().map(|(idx, vals)| rsx! {
                div {
                    class: "row",
                    div {
                        class: "col",
                        span {
                            aria_label: "seed-word-number-{((idx * 2) + 1).to_string()}",
                            class: "num disable-select", ((idx * 2) + 1).to_string()
                        },
                        span {
                            aria_label: "seed-word-value-{((idx * 2) + 1).to_string()}",
                            class: "val", vals.first().cloned().unwrap_or_default()
                        }
                    },
                    div {
                        class: "col",
                        span {
                            aria_label: "seed-word-number-{((idx * 2) + 2).to_string()}",
                            class: "num disable-select", ((idx * 2) + 2).to_string()
                        },
                        span {
                            aria_label: "seed-word-value-{((idx * 2) + 2).to_string()}",
                            class: "val", vals.get(1).cloned().unwrap_or_default()
                        }
                    }
                }
            })
        },
        div {
            class: "controls",
            Button {
                text: get_local_text("uplink.go-back"),
                aria_label: "back-button".into(),
                icon: icons::outline::Shape::ChevronLeft,
                onpress: move |_| page.set(AuthPages::CreateOrRecover),
                appearance: Appearance::Secondary
            },
            Button {
                aria_label: "i-saved-it-button".into(),
                text: get_local_text("copy-seed-words.finished"),
                onpress: move |_| {
                    page.set(AuthPages::EnterUserName);
                }
            }
        }
    }
}
