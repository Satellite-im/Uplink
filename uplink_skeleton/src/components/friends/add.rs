use dioxus::prelude::*;
use ui_kit::{
    elements::{
        button::Button,
        input::{Input, Options, Validation},
    },
    icons::Icon,
};
#[allow(non_snake_case)]
pub fn AddFriend(cx: Scope) -> Element {
    let validation_options = Validation {
        max_length: Some(32),
        min_length: Some(4),
        alpha_numeric_only: true,
        no_whitespace: true,
    };

    let input_options = Options {
        with_validation: Some(validation_options),
        replace_spaces_underscore: false,
        with_clear_btn: true,
        with_label: "Find Someone".into(),
        ..Options::default()
    };
    cx.render(rsx!(
        div {
            class: "add-friend",
            Input {
                placeholder: "Username#0000...".into(),
                icon: Icon::MagnifyingGlass,
                options: input_options
            },
            Button {
                icon: Icon::Plus,
                text: "Add".into(),
            }
        }
    ))
}
