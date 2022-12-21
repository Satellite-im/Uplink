use dioxus::prelude::*;
use fluent_templates::Loader;
use kit::{
    elements::{
        button::Button,
        input::{Input, Options, Validation},
        label::Label,
    },
    icons::Icon,
};

use crate::{APP_LANG, LOCALES};

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

    let find_someone = LOCALES
        .lookup(&*APP_LANG.read(), "friends.add")
        .unwrap_or_default();

    let add = LOCALES
        .lookup(&*APP_LANG.read(), "uplink.add")
        .unwrap_or_default();

    let placeholder = LOCALES
        .lookup(&*APP_LANG.read(), "friends.placeholder")
        .unwrap_or_default();

    cx.render(rsx!(
        div {
            class: "add-friend",
            Label {
                text: find_someone,
            },
            div {
                class: "body",
                Input {
                    placeholder: placeholder,
                    icon: Icon::MagnifyingGlass,
                    options: input_options
                },
                Button {
                    icon: Icon::Plus,
                    text: add,
                }
            }
        }
    ))
}
