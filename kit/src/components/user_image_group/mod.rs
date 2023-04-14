use crate::{components::user_image::UserImage, elements::label::Label, User};
use dioxus::{events::MouseEvent, prelude::*};

#[derive(Props)]
pub struct Props<'a> {
    loading: Option<bool>,
    participants: Vec<User>,
    onpress: Option<EventHandler<'a, MouseEvent>>,
    typing: Option<bool>,
    with_username: Option<String>,
}

#[allow(non_snake_case)]
pub fn UserImageGroup<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let is_pressable = cx.props.onpress.is_some();
    // this is "participants.len() - 3" because:
    // UserImageGroup is supposed to render at most 3 participants. the rest are supposed to be added as a "+n" later
    // the values for count has 1 subtracted (self counts as 1)
    let additional_participants = cx.props.participants.len() as i64 - 3;
    let is_group = cx.props.participants.len() > 1;

    let loading = cx.props.loading.unwrap_or_default() || cx.props.participants.is_empty();

    cx.render(rsx! (
        if loading {
            rsx! (
                div {
                    class: "user-group-skeletal",
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
                        aria_label: "user-image-group-wrap",
                        class: {
                            format_args!("user-image-group-wrap {} {}", if is_pressable { "pressable" } else { "" }, if is_group { "group" } else { "" })
                        },
                        onclick: move |e| { let _ = cx.props.onpress.as_ref().map(|f| f.call(e)); },
                        rsx!(
                            cx.props.participants.iter().map(|user| {
                                rsx!(
                                    UserImage {
                                        platform: user.platform,
                                        status: user.status,
                                        image: user.photo.clone(),
                                        on_press: move |e| { let _ = cx.props.onpress.as_ref().map(|f| f.call(e)); },
                                    }
                                )
                            }),
                            div {
                                class: "plus-some",
                                aria_label: "plus-some",
                                (additional_participants > 0).then(|| rsx!(
                                    if cx.props.typing.unwrap_or_default() {
                                        rsx!(
                                            div { class: "dot dot-1" },
                                            div { class: "dot dot-2" },
                                            div { class: "dot dot-3" }
                                        )
                                    } else {
                                        rsx! (
                                            p {
                                                "+{additional_participants}"
                                            }
                                        )
                                    }
                                ))
                            }
                        )
                    },
                    cx.props.with_username.as_ref().map(|username| rsx!(
                        Label {
                            text: username.to_string()
                        }
                    ))
                }
            )
        }
    ))
}
