use dioxus::prelude::*;

use crate::{icons::Icon, elements::{input::Input, label::Label, button::Button, Appearance}};

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
    #[props(optional)]
    remote: Option<bool>,
    message: String,
    onclose: EventHandler<'a>,
    children: Element<'a>,
}

#[allow(non_snake_case)]
pub fn Reply<'a>(cx: Scope<'a, ReplyProps<'a>>) -> Element<'a> {
    let remote = &cx.props.remote.unwrap_or_default();

    cx.render(
        rsx! (
            div {
                class: "inline-reply",
                Label {
                    text: "Replying to:".into()
                },
                Button {
                    small: true,
                    appearance: Appearance::Secondary,
                    icon: Icon::XMark,
                    onpress: move |_| cx.props.onclose.call(()),
                },
                div {
                    class: "content",
                    remote.then(|| rsx!(&cx.props.children)),
                    p {
                        class: {
                            format_args!("reply-text message {}", if *remote { "remote" } else { "" })
                        },
                        "{cx.props.message}"
                    }
                    (!remote).then(|| rsx!(&cx.props.children)),
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