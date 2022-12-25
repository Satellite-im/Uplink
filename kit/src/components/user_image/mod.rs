use dioxus::{
    core::UiEvent,
    events::{MouseData, MouseEvent},
    prelude::*,
};

use crate::{
    components::indicator::{Indicator, Platform, Status},
    elements::label::Label,
};

#[derive(Props)]
pub struct Props<'a> {
    #[props(optional)]
    loading: Option<bool>,
    #[props(optional)]
    image: Option<String>,
    #[props(optional)]
    typing: Option<bool>,
    #[props(optional)]
    with_username: Option<String>,
    #[props(optional)]
    onpress: Option<EventHandler<'a, MouseEvent>>,
    status: Status,
    platform: Platform,
}

pub fn get_image(cx: &Scope<Props>) -> String {
    cx.props.image.clone().unwrap_or_default()
}

/// Tells the parent the user_image was interacted with.
pub fn emit(cx: &Scope<Props>, e: UiEvent<MouseData>) {
    match &cx.props.onpress {
        Some(f) => f.call(e),
        None => {}
    }
}

#[allow(non_snake_case)]
pub fn UserImage<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let image_data: String = get_image(&cx);
    let status = &cx.props.status;
    let platform = &cx.props.platform;
    let typing = &cx.props.typing.unwrap_or_default();
    let username = &cx.props.with_username.clone().unwrap_or_default();
    let pressable = &cx.props.onpress.is_some();

    let loading = &cx.props.loading.unwrap_or_default();

    cx.render(rsx!(if *loading {
        rsx!(UserImageLoading {})
    } else {
        rsx!(
            div {
                class: {
                    format_args!("user-image-wrap {}", if *pressable { "pressable" } else { "" })
                },
                onclick: move |e| emit(&cx, e),
                div {
                    class: "user-image",
                    div {
                        class: "image",
                        style: "background-image: url('{image_data}');"
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
        )
    }))
}

#[allow(non_snake_case)]
pub fn UserImageLoading(cx: Scope) -> Element {
    cx.render(rsx!(div {
        class: "skeletal user-image-loading"
    }))
}
