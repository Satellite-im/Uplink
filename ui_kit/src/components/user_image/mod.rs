use dioxus::prelude::*;

use crate::components::indicator::{Indicator, Platform, Status};

const STYLE: &str = include_str!("./style.css");

#[derive(Eq, PartialEq, Props)]
pub struct Props {
    #[props(optional)]
    loading: Option<bool>,
    #[props(optional)]
    image: Option<String>,
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

    cx.render(rsx! (
        style { "{STYLE}" },
        div {
            class: "user-image",
            div {
                class: "image",
                style: "background-image: url('{image_data}');",
            },
            Indicator {
                status: *status,
                platform: *platform,
            }
        }
    ))
}
