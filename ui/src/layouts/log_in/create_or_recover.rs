use common::{language::get_local_text, state::State};
use dioxus::prelude::*;
use kit::elements::button::Button;

use crate::get_app_style;

use super::AuthPages;

// styles for this layout are in layouts/style.scss
#[component]
pub fn Layout(cx: Scope, page: UseState<AuthPages>) -> Element {
    let state = use_ref(cx, State::load);

    cx.render(rsx!(
        style {get_app_style(&state.read())},
        div {
            id: "create-or-recover-layout",
            aria_label: "create-or-recover-layout",

            div {
                class: "title",
                get_local_text("create-or-recover")
            },
            div {
                class: "instructions",
                get_local_text("create-or-recover.instructions")
            },
            div {
                class: "button-container",
                Button {
                    text: get_local_text("create-or-recover.create"),
                    onpress: move |_| {
                        page.set(AuthPages::CreateAccount);
                    }
                },
                Button {
                    text: get_local_text("create-or-recover.recover"),
                    onpress: move |_| {
                        page.set(AuthPages::RecoverAccount);
                    }
                },
            }
        }
    ))
}
