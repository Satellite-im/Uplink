use common::{icons, language::get_local_text, state::State};
use dioxus::prelude::*;
use kit::elements::{button::Button, Appearance};

use crate::get_app_style;

use super::AuthPages;

// styles for this layout are in layouts/style.scss
#[component]
pub fn Layout(cx: Scope, page: UseState<AuthPages>) -> Element {
    let state = use_ref(cx, State::load);

    cx.render(rsx!(
        style {get_app_style(&state.read())},
        div {
            id: "enter-seed-words-layout",
            aria_label: "enter-seed-words-layout",

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
                get_local_text("enter-seed-words")
            },
            div {
                class: "instructions",
                get_local_text("enter-seed-words.instructions")
            },
        }
    ))
}
