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
            id: "copy-seed-words-layout",
            aria_label: "copy-seed-words-layout",
        }
    ))
}
