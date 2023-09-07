use std::collections::HashSet;

use common::state::pending_message::progress_file;
use common::warp_runner::thumbnail_to_base64;
//use common::icons::outline::Shape as Icon;
use derive_more::Display;
use dioxus::prelude::*;
use linkify::{LinkFinder, LinkKind};
use pulldown_cmark::{CodeBlockKind, Options, Tag};
use warp::{
    constellation::{file::File, Progression},
    logging::tracing::log,
};

use common::icons::outline::Shape as Icon;

use crate::{components::embeds::file_embed::FileEmbed, elements::textarea};

use super::embeds::link_embed::EmbedLinks;

#[derive(Eq, PartialEq, Clone, Copy, Display)]
pub enum Order {
    #[display(fmt = "message-first")]
    First,

    #[display(fmt = "message-middle")]
    Middle,

    #[display(fmt = "message-last")]
    Last,
}

#[derive(Eq, PartialEq, Clone)]
pub struct ReactionAdapter {
    pub emoji: String,
    pub alt: String,
    pub self_reacted: bool,
    pub reaction_count: usize,
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

    reactions: Vec<ReactionAdapter>,

    // An optional field that, if set to true, will add a CSS class of "remote" to the div element.
    remote: Option<bool>,

    // An optional field that, if set, will be used to determine the ordering of the div element relative to other Message elements.
    // The value will be converted to a string using the Order enum's fmt::Display implementation and used as a CSS class of the div element.
    // If not set, the default value of Order::Last will be used.
    order: Option<Order>,

    // available for download
    attachments: Option<Vec<File>>,

    // attachments which are being downloaded
    #[props(!optional)]
    attachments_pending_download: Option<HashSet<File>>,

    /// called when an attachment is downloaded
    on_download: EventHandler<'a, File>,

    /// called when editing is completed
    on_edit: EventHandler<'a, String>,

    /// If true, the markdown parser will be rendered
    parse_markdown: bool,
    // called when a reaction is clicked
    on_click_reaction: EventHandler<'a, String>,

    // Indicates whether this message is pending to be uploaded or not
    pending: bool,

    // Progress for attachments which are being uploaded
    attachments_pending_uploads: Option<Vec<Progression>>,

    pinned: bool,
}

fn wrap_links_with_a_tags(text: &str) -> String {
    let re = regex::Regex::new(r#"(?i)\b((?:(?:https?://|www\.)[^\s()<>]+|\(([^\s()<>]+|(\([^\s()<>]+\)))*\))+(?:\(([^\s()<>]+|(\([^\s()<>]+\)))*\)|[^\s`!()\[\]{};:'".,<>?«»“”‘’]))"#).unwrap();

    re.replace_all(text, |caps: &regex::Captures| {
        let url = caps.get(0).unwrap().as_str();
        if url.starts_with("www.") {
            format!("<a href=\"https://{}\">{}</a>", url, url)
        } else {
            format!("<a href=\"{}\">{}</a>", url, url)
        }
    })
    .into_owned()
}

#[allow(non_snake_case)]
pub fn Message<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    //  log::trace!("render Message");
    let text = cx.props.with_text.clone().unwrap_or_default();
    let loading = cx.props.loading.unwrap_or_default();
    let is_remote = cx.props.remote.unwrap_or_default();
    let order = cx.props.order.unwrap_or(Order::Last);

    // note: the class "remote" will display the reaction at flex-start, which starts at the bottom left corner of the message.
    // omitting the class will display the reactions starting from the bottom right corner
    let remote_class = ""; //if is_remote { "remote" } else { "" };
    let reactions_class = format!("message-reactions-container {remote_class}");

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
            rsx!(FileEmbed {
                key: "{key}",
                filename: file.name(),
                filesize: file.size(),
                thumbnail: thumbnail_to_base64(file),
                big: true,
                remote: is_remote,
                download_pending: cx
                    .props
                    .attachments_pending_download
                    .as_ref()
                    .map(|x| x.contains(file))
                    .unwrap_or(false),
                on_press: move |_| cx.props.on_download.call(file.clone()),
            })
        })
    });

    let pending_attachment_list = cx.props.attachments_pending_uploads.as_ref().map(|vec| {
        vec.iter().map(|prog| {
            let file = progress_file(prog);
            rsx!(FileEmbed {
                key: "{file}",
                filename: file,
                remote: is_remote,
                download_pending: false,
                with_download_button: false,
                progress: prog,
                on_press: move |_| {},
            })
        })
    });

    // if markdown support is enabled, we will create it, otherwise we will just pass text.
    let mut formatted_text = if cx.props.parse_markdown {
        markdown(&text)
    } else {
        text
    };

    formatted_text = wrap_links_with_a_tags(&formatted_text);
    let formatted_text_clone = formatted_text.clone();

    cx.render(rsx! (
        cx.props.pinned.then(|| {
            rsx!(div {
                class: "pin-indicator",
                aria_label: "pin-indicator",
                common::icons::Icon {
                    ..common::icons::IconProps {
                        class: None,
                        size: 14,
                        fill:"currentColor",
                        icon: Icon::Pin,
                        disabled: false,
                        disabled_fill: "#9CA3AF"
                    },
                },
            })
        }),
        div {
            class: {
                format_args!(
                    "message {} {} {} {}",
                    if loading {
                        "loading"
                    } else { "" },
                    if is_remote {
                        "remote"
                    } else { "" },
                    if cx.props.order.is_some() {
                        order.to_string()
                    } else { "".into() },
                    if cx.props.pending {
                        "message-pending"
                    } else { "" }
                )
            },
            aria_label: {
                format_args!(
                    "message-{}-{}",
                    if is_remote {
                        "remote"
                    } else { "local" },
                    if cx.props.order.is_some() {
                        order.to_string()
                    } else { "".into() }
                )
            },
            white_space: "pre-wrap",
            (cx.props.with_content.is_some()).then(|| rsx! (
                    div {
                    class: "content",
                    cx.props.with_content.as_ref(),
                },
            )),
            (cx.props.with_text.is_some() && cx.props.editing).then(||
                rsx! (
                    p {
                        class: "text",
                        aria_label: "message-text",
                        rsx! (
                            EditMsg {
                                id: cx.props.id.clone(),
                                text: formatted_text,
                                on_enter: move |update| {
                                    cx.props.on_edit.call(update);
                                }
                            }
                        )
                    }
                )
            ),
            (cx.props.with_text.is_some() && !cx.props.editing).then(|| rsx!(
                ChatText {
                    text: formatted_text_clone,
                    remote: is_remote,
                    pending: cx.props.pending,
                }
            )),
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
            pending_attachment_list.map(|node| {
                rsx!(node)
            })
        },
        div {
            class: "{reactions_class}",
            aria_label: "message-reaction-container",
            cx.props.reactions.iter().map(|reaction| {
                let reaction_count = reaction.reaction_count;
                let emoji = &reaction.emoji;
                let alt = &reaction.alt;

                rsx!(
                    div {
                         alt: "{alt}",
                        class:
                            format_args!("emoji-reaction {}", if reaction.self_reacted {
                            "emoji-reaction-self"
                        } else { "" }),
                        aria_label: {
                            format_args!(
                                "emoji-reaction-{}",
                                if reaction.self_reacted {
                                    "self"
                                } else { "remote" }
                            )
                        },
                        onclick: move |_| {
                            cx.props.on_click_reaction.call(emoji.clone());
                        },
                        "{emoji} {reaction_count}"
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

fn replace_tags(s: &str) -> String {
    let mut result = String::new();
    let mut inside_strong = false;
    let mut inside_em = false;

    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '_' {
            if let Some(&next) = chars.peek() {
                if next == '_' {
                    if inside_strong {
                        result.push_str("</strong>");
                    } else {
                        result.push_str("<strong>");
                    }
                    inside_strong = !inside_strong;
                    chars.next(); // Consume the second underscore
                } else {
                    result.push(c);
                }
            } else {
                result.push(c);
            }
        } else if c == '*' {
            if let Some(&next) = chars.peek() {
                if next == '*' {
                    if inside_em {
                        result.push_str("</em>");
                    } else {
                        result.push_str("<em>");
                    }
                    inside_em = !inside_em;
                    chars.next(); // Consume the second asterisk
                } else {
                    result.push(c);
                }
            } else {
                result.push(c);
            }
        } else {
            result.push(c);
        }
    }

    result
}

fn restore_tags(s: &str) -> String {
    s.replace("<strong>", "__")
        .replace("</strong>", "__")
        .replace("<em>", "*")
        .replace("</em>", "*")
}

#[allow(non_snake_case)]
fn EditMsg<'a>(cx: Scope<'a, EditProps<'a>>) -> Element<'a> {
    log::trace!("rendering EditMsg");
    let mut input = cx.props.text.clone();
    let length = input.len();
    if input.ends_with('\n') {
        input.truncate(length - 1);
    }
    if input.starts_with("<p>") {
        if let Some(remainder) = input.strip_prefix("<p>") {
            input = remainder.to_string();
        }
    }
    input = restore_tags(&input);

    cx.render(rsx!(textarea::Input {
        id: cx.props.id.clone(),
        aria_label: "edit-message-input".into(),
        ignore_focus: false,
        value: input,
        onchange: move |_| {},
        onreturn: move |(s, is_valid, _): (String, bool, _)| {
            if is_valid && !s.is_empty() {
                let new_replacement = replace_tags(&s);
                cx.props.on_enter.call(new_replacement);
            } else {
                cx.props.on_enter.call(cx.props.text.clone());
            }
        }
    }))
}

#[derive(Props, PartialEq)]
pub struct ChatMessageProps {
    text: String,
    remote: bool,
    pending: bool,
}

#[allow(non_snake_case)]
pub fn ChatText(cx: Scope<ChatMessageProps>) -> Element {
    let finder = LinkFinder::new();
    let links: Vec<String> = finder
        .spans(&cx.props.text)
        .filter(|e| matches!(e.kind(), Some(LinkKind::Url)))
        .map(|e| e.as_str().to_string())
        .collect();

    // this is broken. may be fixed later.
    let _texts = finder.spans(&cx.props.text).map(|e| match e.kind() {
        Some(LinkKind::Url) => {
            rsx!(
                a {
                    href: e.as_str(),
                    e.as_str()
                }
            )
        }
        _ => rsx!(e.as_str()),
    });

    // not really
    let dangerous_text = cx.props.text.clone();

    cx.render(rsx!(
        div {
            class: format_args!(
                "{}",
                if cx.props.pending {
                    "pending-text"
                } else { "text" }
            ),
            p {
                class: format_args!(
                    "{}",
                    if cx.props.pending {
                        "pending-text"
                    } else { "text" }
                ),
                aria_label: "message-text",
                dangerous_inner_html: "{dangerous_text}",
            },
            links.first().and_then(|l| cx.render(rsx!(
                EmbedLinks {
                    link: l.to_string(),
                    remote: cx.props.remote
                })
            ))
        }
    ))
}

// todo: please add unit tests
pub fn markdown(text: &str) -> String {
    let lines: Vec<String> = text
        .lines()
        .map(|x| x.trim())
        .map(|line| {
            if line.starts_with('>') {
                format!("\\{}", line)
            } else {
                line.to_string()
            }
        })
        .collect();

    let mut options = Options::empty();
    options.insert(Options::ENABLE_STRIKETHROUGH);

    let mut html_output = String::new();
    let mut in_paragraph = false;
    let mut in_code_block = false;

    for line in lines {
        let parser = pulldown_cmark::Parser::new_ext(&line, options);
        for event in parser {
            match event {
                pulldown_cmark::Event::Start(Tag::Paragraph) => {
                    in_paragraph = true;
                    html_output.push_str("<p>");
                }
                pulldown_cmark::Event::End(Tag::Paragraph) => {
                    in_paragraph = false;
                }
                pulldown_cmark::Event::Text(t) => {
                    let txt: pulldown_cmark::CowStr<'_> = if in_paragraph {
                        t.replace("\n\n", "<br/>").into()
                    } else {
                        t
                    };
                    pulldown_cmark::html::push_html(
                        &mut html_output,
                        std::iter::once(pulldown_cmark::Event::Text(txt)),
                    );
                }
                pulldown_cmark::Event::Start(pulldown_cmark::Tag::CodeBlock(code_block_kind)) => {
                    in_code_block = true;
                    match code_block_kind {
                        CodeBlockKind::Fenced(language) => {
                            let language = if language.is_empty() {
                                "text"
                            } else {
                                &language
                            };

                            html_output
                                .push_str(&format!("<pre><code class=\"language-{}\">", language))
                        }
                        _ => html_output.push_str("<pre><code class=\"language-text\">"),
                    }
                }
                pulldown_cmark::Event::End(pulldown_cmark::Tag::CodeBlock(_)) => {
                    if in_code_block && line == "```" {
                        in_code_block = false;
                        // HACK: To close block code is necessary to push tags 2 times
                        html_output.push_str("</code></pre>");
                        html_output.push_str("</code></pre>");
                    }
                }
                _ => pulldown_cmark::html::push_html(&mut html_output, std::iter::once(event)),
            }
        }

        html_output.push('\n');
    }

    html_output
}
