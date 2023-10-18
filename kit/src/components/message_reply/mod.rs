use common::warp_runner::thumbnail_to_base64;
use derive_more::Display;
use dioxus::prelude::*;

use warp::{constellation::file::File, crypto::DID};

use crate::components::embeds::file_embed::FileEmbed;

use super::message::format_text;

#[derive(Eq, PartialEq, Clone, Copy, Display)]
pub enum Order {
    #[display(fmt = "message-first")]
    First,

    #[display(fmt = "message-middle")]
    Middle,

    #[display(fmt = "message-last")]
    Last,
}

#[derive(Props)]
pub struct Props<'a> {
    #[props(optional)]
    user_image: Option<Element<'a>>,
    #[props(optional)]
    loading: Option<bool>,
    #[props(optional)]
    with_text: Option<String>,
    #[props(optional)]
    with_attachments: Option<Vec<File>>,
    #[props(optional)]
    remote: Option<bool>,
    #[props(optional)]
    remote_message: Option<bool>,
    #[props(optional)]
    with_prefix: Option<String>,
    #[props(optional)]
    sender_did: Option<DID>,
    #[props(optional)]
    replier_did: Option<DID>,
    markdown: Option<bool>,
    transform_ascii_emojis: Option<bool>,
}

#[allow(non_snake_case)]
pub fn MessageReply<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let text = format_text(
        &cx.props.with_text.clone().unwrap_or_default(),
        cx.props.markdown.unwrap_or_default(),
        cx.props.transform_ascii_emojis.unwrap_or_default(),
    );
    let prefix = cx.props.with_prefix.clone().unwrap_or_default();
    let loading = cx.props.loading.unwrap_or_default();
    let remote = cx.props.remote.unwrap_or_default();
    let remote_message = cx.props.remote_message.unwrap_or_default();
    let sender_did = cx.props.sender_did.as_ref().cloned();
    let replier_did = cx.props.replier_did.as_ref().cloned();

    let has_attachments = cx
        .props
        .with_attachments
        .as_ref()
        .map(|v| !v.is_empty())
        .unwrap_or(false);

    let attachment_list = cx.props.with_attachments.as_ref().map(|vec| {
        vec.iter().map(|file| {
            let key = file.id();
            rsx!(FileEmbed {
                key: "{key}",
                filename: file.name(),
                filesize: file.size(),
                thumbnail: thumbnail_to_base64(file),
                with_download_button: false,
                remote: remote,
                on_press: move |_| {},
            })
        })
    });

    cx.render(rsx! (
        div {
            class: {
                format_args!(
                    "message-reply {} {}",
                    if loading {
                        "loading"
                    } else { "" },
                    if remote {
                        "remote"
                    } else { "" },
                )
            },
            aria_label: "message-reply",
            (cx.props.user_image.is_some() && remote_message).then(|| rsx! (
                cx.props.user_image.as_ref()
            )),
            (cx.props.with_text.is_some() || has_attachments).then(|| rsx! (
                div {
                    class: "content",
                    (!prefix.is_empty()).then(|| rsx!(
                        p {
                            class: "prefix",
                            "{prefix}"
                        },
                    )),
                    p {
                        class: {
                            format_args!("text {}", if remote_message { "remote-text" } else { "" })
                        },
                        background: if replier_did == sender_did {"var(--secondary)"} else {"var(--secondary-dark)"},
                        dangerous_inner_html: "{text}",
                        has_attachments.then(|| {
                            rsx!(
                                attachment_list.map(|list| {
                                    rsx!( list )
                                })
                            )
                        })
                    }
                }
            )),
            (cx.props.user_image.is_some() && !remote_message).then(|| rsx! (
                cx.props.user_image.as_ref()
            )),
        }
    ))
}
