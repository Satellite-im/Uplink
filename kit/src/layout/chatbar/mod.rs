use dioxus::prelude::*;

use crate::elements::{button::Button, label::Label, textarea, Appearance};

use common::icons;

pub type To = &'static str;

#[derive(Clone, PartialEq)]
pub struct Route {
    pub to: To,
    pub icon: icons::outline::Shape,
    pub name: &'static str,
}

#[derive(Default)]
pub struct ReplyInfo<'a> {
    pub user_image: Element<'a>,
    pub message: String,
}

#[derive(Props)]
pub struct Props<'a> {
    placeholder: String,
    #[props(optional)]
    with_replying_to: Option<Element<'a>>,
    #[props(optional)]
    with_file_upload: Option<Element<'a>>,
    #[props(optional)]
    extensions: Option<Element<'a>>,
    #[props(optional)]
    controls: Option<Element<'a>>,
    #[props(optional)]
    loading: Option<bool>,
    onchange: EventHandler<'a, String>,
    onreturn: EventHandler<'a, String>,
    reset: Option<UseState<bool>>,
}

#[derive(Props)]
pub struct ReplyProps<'a> {
    label: String,
    #[props(optional)]
    remote: Option<bool>,
    message: String,
    onclose: EventHandler<'a>,
    children: Element<'a>,
}

#[allow(non_snake_case)]
pub fn Reply<'a>(cx: Scope<'a, ReplyProps<'a>>) -> Element<'a> {
    let remote = cx.props.remote.unwrap_or_default();

    cx.render(rsx! (
        div {
            class: "inline-reply",
            Label {
                text: cx.props.label.clone(),
            },
            Button {
                small: true,
                appearance: Appearance::Secondary,
                icon: icons::outline::Shape::XMark,
                onpress: move |_| cx.props.onclose.call(()),
            },
            div {
                class: "content",
                remote.then(|| rsx!(&cx.props.children)),
                p {
                    class: {
                        format_args!("reply-text message {}", if remote { "remote" } else { "" })
                    },
                    "{cx.props.message}"
                }
                (!remote).then(|| rsx!(&cx.props.children)),
            }
        }
    ))
}

#[allow(non_snake_case)]
pub fn Chatbar<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    cx.render(rsx!(
        div {
            class: "chatbar",
            cx.props.with_replying_to.as_ref(),
            cx.props.with_file_upload.as_ref(),
            // apologies for the crappy code.
            match &cx.props.reset {
                Some(hook) => {
                    rsx!(
                        textarea::Input {
                            disabled: cx.props.loading.unwrap_or_default(),
                            placeholder: cx.props.placeholder.clone(),
                            allow_line_breaks: true,
                            reset: hook.clone(),
                            onchange: move |(v, _)| cx.props.onchange.call(v),
                            onreturn: move |(v, _, _)| cx.props.onreturn.call(v),
                        }
                    )
                }
                None => {
                    rsx!(
                        textarea::Input {
                            disabled: cx.props.loading.unwrap_or_default(),
                            placeholder: cx.props.placeholder.clone(),
                            allow_line_breaks: true,
                            onchange: move |(v, _)| cx.props.onchange.call(v),
                            onreturn: move |(v, _, _)| cx.props.onreturn.call(v),
                        }
                    )
                }
            },
            cx.props.extensions.as_ref(),
            div {
                class: "controls",
                cx.props.controls.as_ref()
            }
        }
    ))
}
