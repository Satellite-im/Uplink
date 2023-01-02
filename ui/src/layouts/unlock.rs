use dioxus::prelude::*;
use dioxus_desktop::{use_window, LogicalSize};
use kit::{
    elements::{
        button::Button,
        input::{Input, Options, Validation},
        label::Label,
    },
    icons::Icon,
};

#[allow(non_snake_case)]
pub fn UnlockLayout(cx: Scope) -> Element {
    let _window = use_window(cx);
    // window.set_inner_size(Size::Logical(LogicalSize {
    //     width: 100.0,
    //     height: 100.0,
    // }));
    // Set up validation options for the input field
    let validation_options = Validation {
        // The input should have a maximum length of 32
        max_length: Some(32),
        // The input should have a minimum length of 4
        min_length: Some(4),
        // The input should only contain alphanumeric characters
        alpha_numeric_only: false,
        // The input should not contain any whitespace
        no_whitespace: true,
    };

    let disabled = use_state(cx, || false);

    let desktop = use_window(cx);

    // TODO: we should make the window smaller during the inital setup steps.

    desktop.set_inner_size(LogicalSize {
        width: 500.0,
        height: 300.0,
    });

    cx.render(rsx!(
        div {
            id: "unlock-layout",
            onmousedown: move |_| {
                desktop.drag();
            },
            Label {
                text: "Choose your Password".into(),
            },
            p {
                class: "info",
                "Your password is used to encrypt your data. It is never sent to any server. You should use a strong password that you don't use anywhere else."
                br {},
                span {
                    class: "warning",
                    "If you forget this password we cannot help you retrieve it."
                }
            },
            Input {
                is_password: true,
                icon: Icon::Key,
                disabled: **disabled,
                placeholder: "Enter Password".into(),
                options: Options {
                    with_validation: Some(validation_options),
                    with_clear_btn: true,
                    ..Default::default()
                }
            },
            Button {
                text: "Create Account".into(),
                appearance: kit::elements::Appearance::Primary,
                icon: Icon::Check,
                onpress: move |_| {
                    disabled.set(true);
                }
            }
        }
    ))
}
