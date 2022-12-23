use crate::{
    elements::{button::Button, label::Label, Appearance},
    icons::{Icon, IconElement},
};

use dioxus::prelude::*;

#[derive(PartialEq, Props)]
pub struct Props {
    #[props(optional)]
    icon: Option<Icon>,
    #[props(optional)]
    with_title: Option<String>,
    #[props(optional)]
    with_content: Option<String>,
    #[props(optional)]
    appearance: Option<Appearance>,
}

/// Generates the optional icon providing a fallback.
/// If there is no icon provided, the toast should not call this.
pub fn get_icon(cx: &Scope<Props>) -> Icon {
    match &cx.props.icon {
        Some(icon) => icon.to_owned(),
        None => Icon::QuestionMarkCircle,
    }
}

#[allow(non_snake_case)]
pub fn Toast(cx: Scope<Props>) -> Element {
    let content = cx.props.with_content.clone().unwrap_or_default();
    let title = cx.props.with_title.clone().unwrap_or_default();

    cx.render(rsx!(
        div {
            class: "toast",
            (cx.props.icon.is_some()).then(|| rsx!(
                span {
                    class: "toast-icon",
                    IconElement {
                        icon: get_icon(&cx)
                    }
                }
            )),
            div {
                class: "toast-content",
                Label {
                    text: title,
                },
                p {
                    "{content}",
                }
            },
            Button {
                icon: Icon::XMark,
                appearance: Appearance::Secondary,
                onpress: move |_| {
                    // cx.emit(UiEvent::RemoveElement);
                }
            }
        }
    ))
}
