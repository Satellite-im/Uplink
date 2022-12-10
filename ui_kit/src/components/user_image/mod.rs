use dioxus::prelude::*;

use crate::{components::indicator::{Indicator, Platform, Status}, elements::label::Label};

const STYLE: &str = include_str!("./style.css");

#[derive(Eq, PartialEq, Props)]
pub struct Props {
    #[props(optional)]
    loading: Option<bool>,
    #[props(optional)]
    image: Option<String>,
    #[props(optional)]
    typing: Option<bool>,
    #[props(optional)]
    with_username: Option<String>,
    status: Status,
    platform: Platform,
}

pub fn get_image(cx: &Scope<Props>) -> String {
    cx.props
        .image
        .as_ref()
        .map(|image| image.split_whitespace().collect())
        .unwrap_or_default()
}

#[allow(non_snake_case)]
pub fn UserImage(cx: Scope<Props>) -> Element {
    let image_data: String = get_image(&cx);
    let status = &cx.props.status;
    let platform = &cx.props.platform;
    let typing = &cx.props.typing.unwrap_or_default();

    let username = &cx.props.with_username.clone().unwrap_or_default();

    cx.render(rsx! (
        style { "{STYLE}" },
        div {
            class: "user-image-wrap",
            div {
                class: "user-image",
                div {
                    class: "image",
                    style: "background-image: url('{image_data}');",
                },
                typing.then(|| rsx!(
                    div {
                        class: "profile-typing",
                        div { class: "dot dot-1" },
                        div { class: "dot dot-2" },
                        div { class: "dot dot-3" }
                    }
                ))
                Indicator {
                    status: *status,
                    platform: *platform,
                }
            },
            (cx.props.with_username.is_some()).then(|| rsx!(
                Label {
                    text: username.to_string()
                }
            ))
        }
    ))
}
