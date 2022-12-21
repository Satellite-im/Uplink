use std::time::Duration;

use dioxus::{
    core::UiEvent,
    events::{MouseData, MouseEvent},
    prelude::*,
};

#[derive(Props)]
pub struct Props<'a> {
    username: String,
    user_image: Element<'a>,
    subtext: String,
    timestamp: Option<u64>,
    #[props(optional)]
    with_badge: Option<String>,
    #[props(optional)]
    active: Option<bool>,
    #[props(optional)]
    onpress: Option<EventHandler<'a, MouseEvent>>,
}

pub fn get_time_ago(cx: &Scope<Props>) -> String {
    let f = timeago::Formatter::new();

    match cx.props.timestamp {
        Some(d) => f.convert(Duration::from_millis(d)),
        None => "".into(),
    }
}

/// Generates the optional badge for the user.
/// If there is no badge provided, we'll return an empty string.
pub fn get_badge(cx: &Scope<Props>) -> String {
    match &cx.props.with_badge {
        Some(val) => val.to_owned(),
        None => String::from(""),
    }
}

/// Tells the parent the user was interacted with.
pub fn emit(cx: &Scope<Props>, e: UiEvent<MouseData>) {
    match &cx.props.onpress {
        Some(f) => f.call(e),
        None => {}
    }
}

#[allow(non_snake_case)]
pub fn User<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let time_ago = get_time_ago(&cx);
    let badge = get_badge(&cx);
    let active = &cx.props.active.unwrap_or_default();

    cx.render(rsx! (
        div {
            class: {
                format_args!("user {} noselect defaultcursor", if *active { "active" } else { "" })
            },
            onclick: move |e| emit(&cx, e),
            (!badge.is_empty()).then(|| rsx!(
                span {
                    class: "badge",
                    span {
                        class: "badge-prefix",
                        "{time_ago}"
                    }
                    span {
                        class: "badge-count",
                        "{badge}"
                    }
                }
            )),
            &cx.props.user_image,
            div {
                class: "info",
                p {
                    class: "username",
                    "{cx.props.username}"
                },
                p {
                    class: "subtext",
                    "{cx.props.subtext}"
                }
            }
        }
    ))
}
