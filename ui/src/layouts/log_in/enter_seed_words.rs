use common::state::State;
use dioxus::prelude::*;

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
        }
    ))
}
