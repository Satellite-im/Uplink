use common::{state::State, warp_runner::thumbnail_to_base64};
use derive_more::Display;
use dioxus::prelude::*;

use uuid::Uuid;
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
    user_image: Option<Element>,
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
    state: &'a UseSharedState<State>,
    chat: Uuid,
}

#[allow(non_snake_case)]
pub fn MessageReply<'a>(props: Props<'a>) -> Element {
    let text = format_text(
        &props.with_text.clone().unwrap_or_default(),
        props.markdown.unwrap_or_default(),
        props.transform_ascii_emojis.unwrap_or_default(),
        Some((&props.state.read(), &props.chat, true)),
    );
    let prefix = props.with_prefix.clone().unwrap_or_default();
    let loading = props.loading.unwrap_or_default();
    let remote = props.remote.unwrap_or_default();
    let remote_message = props.remote_message.unwrap_or_default();
    let sender_did = props.sender_did.as_ref().cloned();
    let replier_did = props.replier_did.as_ref().cloned();

    let has_attachments = cx
        .props
        .with_attachments
        .as_ref()
        .map(|v| !v.is_empty())
        .unwrap_or(false);

    let attachment_list = props.with_attachments.as_ref().map(|vec| {
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

    rsx! (
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
            (props.user_image.is_some() && remote_message).then(|| rsx! (
                props.user_image.as_ref()
            )),
            (props.with_text.is_some() || has_attachments).then(|| rsx! (
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
            (props.user_image.is_some() && !remote_message).then(|| rsx! (
                props.user_image.as_ref()
            )),
            div {
                class: "connector",
                if props.remote.unwrap_or_default() {
                    "┌"
                } else {
                    "┐"
                }
            }
        }
    )
}
