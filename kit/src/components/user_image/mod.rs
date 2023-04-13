use dioxus::{
    core::Event,
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
    on_press: Option<EventHandler<'a, MouseEvent>>,
    #[props(optional)]
    oncontextmenu: Option<EventHandler<'a, MouseEvent>>,
    status: Status,
    platform: Platform,
}

pub fn get_image(cx: &Scope<Props>) -> String {
    cx.props.image.clone().unwrap_or_default()
}

/// Tells the parent the user_image was interacted with.
pub fn emit(cx: &Scope<Props>, e: Event<MouseData>) {
    match &cx.props.on_press {
        Some(f) => f.call(e),
        None => {}
    }
}

pub fn emit_context(cx: &Scope<Props>, e: Event<MouseData>) {
    match &cx.props.oncontextmenu {
        Some(f) => f.call(e),
        None => {}
    }
}

#[allow(non_snake_case)]
pub fn UserImage<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let image_data: String = get_image(&cx);
    let status = cx.props.status;
    let platform = cx.props.platform;
    let typing = cx.props.typing.unwrap_or_default();
    let username = cx.props.with_username.clone().unwrap_or_default();
    let pressable = cx.props.on_press.is_some();

    let loading = cx.props.loading.unwrap_or_default();

    cx.render(rsx!(if loading {
        rsx!(UserImageLoading {})
    } else {
        rsx!(
            div {
                class: {
                    format_args!("user-image-wrap {} {}", if pressable { "pressable" } else { "" },
                    if cx.props.oncontextmenu.is_some() {"has-context-handler"} else {""})
                },
                aria_label: "user-image-wrap",
                onclick: move |e| emit(&cx, e),
                oncontextmenu: move |e| emit_context(&cx, e),
                div {
                    class: "user-image",
                    aria_label: "User Image",
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
                        status: status,
                        platform: platform,
                    }
                },
                (cx.props.with_username.is_some()).then(|| rsx!(
                    Label {
                        text: username
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
