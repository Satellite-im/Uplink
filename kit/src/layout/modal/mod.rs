use crate::elements::button::Button;
use crate::elements::label::Label;
use crate::elements::Appearance;
use common::icons::outline::Shape as Icon;

use dioxus::prelude::*;

#[derive(Props, Clone)]
pub struct Props {
    open: bool,
    with_title: Option<String>,
    transparent: bool,
    #[props(optional)]
    dont_pad: Option<bool>,
    show_close_button: Option<bool>,
    close_on_click_inside_modal: Option<bool>,
    change_horizontal_position: Option<bool>,
    children: Element,
    onclose: EventHandler<()>,
    class: Option<String>,
    right: Option<String>,
}

#[allow(non_snake_case)]
pub fn Modal(props: Props) -> Element {
    let transparent_class = if props.transparent { "transparent" } else { "" };
    let no_padding_class = if props.dont_pad.unwrap_or_default() {
        "no-padding"
    } else {
        ""
    };

    let horizontal_position_class = if props.change_horizontal_position.unwrap_or_default() {
        "horizontal-position"
    } else {
        ""
    };

    let show_close_button = props.show_close_button.unwrap_or(true);

    let title = props.with_title.clone().unwrap_or_default();

    let close_on_click_inside_modal = props.close_on_click_inside_modal.unwrap_or_default();

    rsx!({
        {
            props.open.then(||
        rsx!(div {
            class: "modal-wrap {transparent_class} {no_padding_class}",
            aria_label: "modal",
            onclick: move |_| {
                props.onclose.call(());
            },
            div {
                class: "modal {props.class.unwrap_or_default()} {horizontal_position_class}",
                right: if props.right.is_some() { props.right.unwrap_or_default() } else { "unset".to_string() },
                onclick: move |e| {
                    if !close_on_click_inside_modal {
                        e.stop_propagation();
                    }
                },
                {(!props.transparent && show_close_button).then(|| rsx!(
                    div {
                        class: "close-btn",
                        aria_label: "close-modal-button",
                        z_index: "10",
                        Button {
                            icon: Icon::XMark,
                            appearance: Appearance::Secondary,
                            onpress: move |_| props.onclose.call(()),
                        },
                    }
                ))},
                {props.with_title.is_some().then(|| rsx!(
                    Label {
                        text: title,
                    }
                ))},
                {&props.children}
            }
        }),
    )
        }
    })
}
