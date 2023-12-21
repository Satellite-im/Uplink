use bip39::{Language, Mnemonic};
use common::{icons, language::get_local_text, state::State};
use dioxus::prelude::*;
use kit::elements::{button::Button, Appearance};

use crate::get_app_style;

use super::AuthPages;

// styles for this layout are in layouts/style.scss
#[component]
pub fn Layout(cx: Scope, page: UseState<AuthPages>, seed_words: UseRef<String>) -> Element {
    let state = use_ref(cx, State::load);

    let words = use_future(cx, (), |_| {
        to_owned![seed_words];
        async move {
            let mnemonic =
                Mnemonic::generate_in(Language::English, 12).expect("mnemonic should succeed");

            seed_words.set(mnemonic.to_string());
            mnemonic
                .to_string()
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
                class: "back-button",
                Button {
                    aria_label: "back-button".into(),
                    icon: icons::outline::Shape::ChevronLeft,
                    onpress: move |_| page.set(AuthPages::CreateOrRecover),
                    appearance: Appearance::Secondary
                },
            },
            div {
                class: "title",
                get_local_text("copy-seed-words")
            },
            div {
                class: "instructions",
                get_local_text("copy-seed-words.instructions")
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

                        span { class: "num", ((idx * 2) + 1).to_string() },
                        span { class: "val", vals.get(0).cloned().unwrap_or_default() }
                    },
                    div {
                        class: "col",

                        span { class: "num", ((idx * 2) + 2).to_string() },
                        span { class: "val", vals.get(1).cloned().unwrap_or_default() }
                    }
                }
            })
        },
        div {
            class: "controls",
            Button {
                text: get_local_text("copy-seed-words.finished"),
                onpress: move |_| {
                    page.set(AuthPages::EnterUserName);
                }
            }
        }
    }
}
