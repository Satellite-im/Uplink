use crate::elements::button::Button;
use crate::elements::label::Label;
use crate::elements::Appearance;
use common::icons::outline::Shape as Icon;

use dioxus::prelude::*;

#[derive(Props)]
pub struct Props<'a> {
    open: bool,
    with_title: Option<String>,
    transparent: bool,
    #[props(optional)]
    dont_pad: Option<bool>,
    show_close_button: Option<bool>,
    close_on_click_inside_modal: Option<bool>,
    children: Element<'a>,
    onclose: EventHandler<'a, ()>,
    class: Option<&'a str>,
}

#[allow(non_snake_case)]
pub fn Modal<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let transparent_class = if cx.props.transparent {
        "transparent"
    } else {
        ""
    };
    let no_padding_class = if cx.props.dont_pad.unwrap_or_default() {
        "no-padding"
    } else {
        ""
    };

    let show_close_button = cx.props.show_close_button.unwrap_or(true);

    let title = cx.props.with_title.clone().unwrap_or_default();

    let close_on_click_inside_modal = cx.props.close_on_click_inside_modal.unwrap_or(true);

    cx.render(rsx!(cx.props.open.then(|| rsx!(
        div {
            class: "modal-wrap {transparent_class} {no_padding_class}",
            aria_label: "modal",
            onclick: move |_| {
                if close_on_click_inside_modal {
                    cx.props.onclose.call(());
                }
            },
            div {
                class: "modal {cx.props.class.unwrap_or_default()}",
                (!cx.props.transparent && show_close_button).then(|| rsx!(
                    div {
                        class: "close-btn",
                        z_index: "10",
                        Button {
                            icon: Icon::XMark,
                            appearance: Appearance::Secondary,
                            onpress: move |_| cx.props.onclose.call(()),
                        },
                    }
                )),
                cx.props.with_title.is_some().then(|| rsx!(
                    Label {
                        text: title,
                    }
                )),
                &cx.props.children
            }
        },
    ))))
}
