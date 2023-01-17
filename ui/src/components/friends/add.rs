use dioxus::prelude::*;
use kit::{
    elements::{
        button::Button,
        input::{Input, Options, Validation},
        label::Label,
    },
    icons::Icon,
};
use shared::language::get_local_text;

#[allow(non_snake_case)]
pub fn AddFriend(cx: Scope) -> Element {
    // Set up validation options for the input field
    let validation_options = Validation {
        // The input should have a maximum length of 32
        max_length: Some(32),
        // The input should have a minimum length of 4
        min_length: Some(4),
        // The input should only contain alphanumeric characters
        alpha_numeric_only: true,
        // The input should not contain any whitespace
        no_whitespace: true,
    };

    // Set up options for the input field
    let input_options = Options {
        // Enable validation for the input field with the specified options
        with_validation: Some(validation_options),
        // Do not replace spaces with underscores
        replace_spaces_underscore: false,
        // Show a clear button inside the input field
        with_clear_btn: true,
        // Use the default options for the remaining fields
        ..Options::default()
    };

    cx.render(rsx!(
        div {
            class: "add-friend",
            Label {
                text: get_local_text("friends.add"),
            },
            div {
                class: "body",
                Input {
                    placeholder: get_local_text("friends.placeholder"),
                    icon: Icon::MagnifyingGlass,
                    options: input_options,
                    aria_label: "Add Someone Input".into()
                },
                Button {
                    icon: Icon::Plus,
                    text: get_local_text("uplink.add"),
                    aria_label: "Add Someone Button".into()
                }
            }
        }
    ))
}
