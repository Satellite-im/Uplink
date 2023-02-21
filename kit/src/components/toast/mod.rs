use crate::elements::{button::Button, label::Label, Appearance};

use common::icons::outline::Shape as Icon;
use common::icons::Icon as IconElement;

use dioxus::prelude::*;
use uuid::Uuid;

#[allow(dead_code)]
//TODO: Remove for appearance when it is used
#[derive(Props)]
pub struct Props<'a> {
    id: Uuid,
    on_hover: EventHandler<'a, Uuid>,
    on_close: EventHandler<'a, Uuid>,
    #[props(!optional)]
    icon: Option<Icon>,
    #[props(!optional)]
    with_title: Option<String>,
    #[props(!optional)]
    with_content: Option<String>,
    #[props(!optional)]
    appearance: Option<Appearance>,
    #[props(optional)]
    aria_label: Option<String>,
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
pub fn Toast<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let content = cx.props.with_content.clone().unwrap_or_default();
    let title = cx.props.with_title.clone().unwrap_or_default();

    cx.render(rsx!(
        div {
            class: "toast",
            aria_label: "Toast Notification",
            onmouseover: move |_| cx.props.on_hover.call(cx.props.id),
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
                onpress: move |_| cx.props.on_close.call(cx.props.id),
            }
        }
    ))
}
