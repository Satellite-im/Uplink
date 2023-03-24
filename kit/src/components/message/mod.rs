//use common::icons::outline::Shape as Icon;
use derive_more::Display;
use dioxus::prelude::*;
use warp::{constellation::file::File, logging::tracing::log};

use crate::{components::file_embed::FileEmbed, elements::textarea};

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
    // Message ID
    id: String,
    // indicates that the message is being edited
    editing: bool,

    // An optional field that, if set to true, will add a CSS class of "loading" to the div element.
    loading: Option<bool>,

    // An optional field that, if set, will be used as the content of a nested div element with a class of "content".
    with_content: Option<Element<'a>>,

    // An optional field that, if set, will be used as the text content of a nested p element with a class of "text".
    with_text: Option<String>,

    // todo: remove unused attribute
    // todo: does this need to be an option like the rest of 'em?
    #[allow(unused)]
    reactions: Vec<warp::raygun::Reaction>,

    // An optional field that, if set to true, will add a CSS class of "remote" to the div element.
    remote: Option<bool>,

    // An optional field that, if set, will be used to determine the ordering of the div element relative to other Message elements.
    // The value will be converted to a string using the Order enum's fmt::Display implementation and used as a CSS class of the div element.
    // If not set, the default value of Order::Last will be used.
    order: Option<Order>,

    // available for download
    attachments: Option<Vec<File>>,

    /// called when an attachment is downloaded
    on_download: EventHandler<'a, String>,

    /// called when editing is completed
    on_edit: EventHandler<'a, String>,
}

#[allow(non_snake_case)]
pub fn Message<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let text = cx.props.with_text.clone().unwrap_or_default();
    // todo: render reactions

    let loading = cx.props.loading.unwrap_or_default();
    let is_remote = cx.props.remote.unwrap_or_default();
    let order = cx.props.order.unwrap_or(Order::Last);

    let has_attachments = cx
        .props
        .attachments
        .as_ref()
        .map(|v| !v.is_empty())
        .unwrap_or(false);

    // todo: pick an icon based on the file extension
    // there's some weirdness here to avoid more nesting. this should make the code easier to read overall
    let attachment_list = cx.props.attachments.as_ref().map(|vec| {
        vec.iter().map(|file| {
            let key = file.id();
            let name = file.name();
            rsx!(FileEmbed {
                key: "{key}",
                filename: file.name(),
                filesize: file.size(),
                remote: is_remote,
                on_press: move |_| cx.props.on_download.call(name.clone()),
            })
        })
    });

    cx.render(rsx! (
        div {
            class: {
                format_args!(
                    "message {} {} {}",
                    if loading {
                        "loading"
                    } else { "" },
                    if is_remote {
                        "remote"
                    } else { "" },
                    if cx.props.order.is_some() {
                        order.to_string()
                    } else { "".into() }
                )
            },
            aria_label: "Message",
            white_space: "pre-wrap",
            (cx.props.with_content.is_some()).then(|| rsx! (
                    div {
                    class: "content",
                    cx.props.with_content.as_ref(),
                },
            )),
            (cx.props.with_text.is_some()).then(||
                rsx! (
                    p {
                        class: "text",
                        aria_label: "message-text",
                        if cx.props.editing {
                            rsx! (
                                EditMsg{
                                    id: cx.props.id.clone(),
                                    text: text.clone(),
                                    on_enter: move |update| {
                                        cx.props.on_edit.call(update);
                                    }
                                }
                            )
                        } else {
                            rsx! ("{text}")
                        }
                    }
                )
            ),
            has_attachments.then(|| {
                rsx!(
                    div {
                        class: "attachment-list",
                        attachment_list.map(|list| {
                            rsx!( list )
                        })
                    }
                )
            })

        }
    ))
}

#[derive(Props)]
struct EditProps<'a> {
    id: String,
    text: String,
    on_enter: EventHandler<'a, String>,
}

#[allow(non_snake_case)]
fn EditMsg<'a>(cx: Scope<'a, EditProps<'a>>) -> Element<'a> {
    log::trace!("rendering EditMsg");
    cx.render(rsx!(textarea::Input {
        id: cx.props.id.clone(),
        focus: true,
        value: cx.props.text.clone(),
        onchange: move |_| {},
        onreturn: move |(s, is_valid, _): (String, bool, _)| {
            if is_valid && !s.is_empty() {
                cx.props.on_enter.call(s);
            } else {
                cx.props.on_enter.call(cx.props.text.clone());
            }
        }
    }))
}
