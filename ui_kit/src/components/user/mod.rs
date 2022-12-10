use std::time::Duration;

use dioxus::{prelude::*, core::UiEvent, events::{MouseData, MouseEvent}};
use uuid::Uuid;

const STYLE: &str = include_str!("./style.css");

#[derive(Props)]
pub struct Props<'a> {
    username: String,
    user_image: Element<'a>,
    subtext: String,
    timestamp: Option<u64>,
    #[props(optional)]
    with_badge: Option<String>,
    #[props(optional)]
    onpress: Option<EventHandler<'a, MouseEvent>>,
}

pub fn get_time_ago(cx: &Scope<Props>) -> String {
    let f = timeago::Formatter::new();

    match cx.props.timestamp {
        Some(d) => f.convert(Duration::from_millis(d)),
        None => "".into()
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
        None => {},
    }
}

#[allow(non_snake_case)]
pub fn User<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let UUID = Uuid::new_v4().to_string();
    let scoped_styles = STYLE.replace("UUID", &UUID);
    let time_ago = get_time_ago(&cx);

    let badge = get_badge(&cx);

    cx.render(rsx! (
        style { "{scoped_styles}" },
        div {
            class: "user user-{UUID} noselect defaultcursor",
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
                class: "user-info",
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