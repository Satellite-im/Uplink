use dioxus::prelude::*;

use crate::{icons::Icon, elements::input::Input, components::user_image};

pub type To = &'static str;

const STYLE: &str = include_str!("./style.css");

#[derive(Clone, PartialEq)]
pub struct Route {
    pub to: To,
    pub icon: Icon,
    pub name: &'static str,
}

#[derive(Default)]
pub struct ReplyInfo<'a> {
    pub user_image: Element<'a>,
    pub message: String,
}

#[derive(Props)]
pub struct Props<'a> {
    #[props(optional)]
    with_replying_to: Option<Element<'a>>,
    #[props(optional)]
    with_file_upload: Option<Element<'a>>,
    #[props(optional)]
    extensions: Option<Element<'a>>,
    #[props(optional)]
    controls: Option<Element<'a>>,
}

#[derive(Props)]
pub struct ReplyProps<'a> {
    message: String,
    children: Element<'a>,
}

pub fn Reply<'a>(cx: Scope<'a, ReplyProps<'a>>) -> Element<'a> {
    cx.render(
        rsx! (
            div {
                class: "inline-reply",
                &cx.props.children,
                p {
                    class: "reply-text",
                    "{cx.props.message}"
                }
            }
        )
    )
}


#[allow(non_snake_case)]
pub fn Chatbar<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    cx.render(
        rsx!(
            style { "{STYLE}" }
            div {
                class: "chatbar",
                &cx.props.with_replying_to,
                &cx.props.with_file_upload,
                Input {
                    placeholder: "Say something...".into(),
                },
                &cx.props.extensions,
                div {
                    class: "controls",
                    &cx.props.controls
                }
            }
        )
    )
}