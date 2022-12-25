use dioxus::{
    core::UiEvent,
    events::{MouseData, MouseEvent},
    prelude::*,
};

use crate::{
    components::user_image::{UserImage, UserImageLoading},
    elements::label::Label,
    User,
};

#[derive(Props)]
pub struct Props<'a> {
    #[props(optional)]
    loading: Option<bool>,
    participants: Vec<User>,
    #[props(optional)]
    onpress: Option<EventHandler<'a, MouseEvent>>,
    #[props(optional)]
    typing: Option<bool>,
    #[props(optional)]
    with_username: Option<String>,
}

pub fn emit(cx: &Scope<Props>, e: UiEvent<MouseData>) {
    match &cx.props.onpress {
        Some(f) => f.call(e),
        None => {}
    }
}

#[allow(non_snake_case)]
pub fn UserImageGroup<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let pressable = &cx.props.onpress.is_some();
    let count: i64 = cx.props.participants.len() as i64 - 3;
    let group = cx.props.participants.len() > 2;
    let username = &cx.props.with_username.clone().unwrap_or_default();
    let single_user = &cx.props.participants[1];

    let loading = &cx.props.loading.unwrap_or_default();

    cx.render(rsx! (
        if *loading {
            rsx! (
                div {
                    class: "user-group-skeletal",
                    UserImageLoading {},
                    (cx.props.with_username.is_some()).then(|| rsx!(
                        div { class: "skeletal skeletal-bar smaller" }
                    ))
                }
            )
        } else {
            rsx! (
                div {
                    class: "user-image-group",
                    div {
                        class: {
                            format_args!("user-image-group-wrap {} {}", if *pressable { "pressable" } else { "" }, if group { "group" } else { "" })
                        },
                        onclick: move |e| emit(&cx, e),
                        if group {
                            rsx!(
                                cx.props.participants.iter().map(|user| {
                                    rsx!(
                                        UserImage {
                                            platform: user.platform,
                                            status: user.status,
                                            image: user.photo.clone()
                                        }
                                    )
                                }),
                                div {
                                    class: "plus-some",
                                    (count > 0).then(|| rsx!(
                                        if cx.props.typing.unwrap_or_default() {
                                            rsx!(
                                                div { class: "dot dot-1" },
                                                div { class: "dot dot-2" },
                                                div { class: "dot dot-3" }
                                            )
                                        } else {
                                            rsx! (
                                                p {
                                                    "+{count}"
                                                }
                                            )
                                        }
                                    ))
                                }
                            )
                        } else {
                            rsx!(
                                UserImage {
                                    platform: single_user.platform,
                                    status: single_user.status
                                }
                            )
                        }
                    }
                    (cx.props.with_username.is_some()).then(|| rsx!(
                        Label {
                            text: username.to_string()
                        }
                    ))
                }
            )
        }
    ))
}
