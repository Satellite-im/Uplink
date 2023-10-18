use std::{collections::HashSet, ops::Range};

use common::state::pending_message::progress_file;
use common::warp_runner::thumbnail_to_base64;
//use common::icons::outline::Shape as Icon;
use derive_more::Display;
use dioxus::prelude::*;
use linkify::{LinkFinder, LinkKind};
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
    transform_ascii_emojis: bool,
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

    let loading_class = loading.then_some("loading").unwrap_or_default();
    let remote_class = is_remote.then_some("remote").unwrap_or_default();
    let order_class = order.to_string();
    let msg_pending_class = cx
        .props
        .pending
        .then_some("message-pending")
        .unwrap_or_default();

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
                   loading_class, remote_class, order_class, msg_pending_class
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
                                text: cx.props.with_text.clone().unwrap_or_default(),
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
                    text: cx.props.with_text.clone().unwrap_or_default(),
                    remote: is_remote,
                    pending: cx.props.pending,
                    markdown: cx.props.parse_markdown,
                    ascii_emoji: cx.props.transform_ascii_emojis,
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

#[allow(non_snake_case)]
fn EditMsg<'a>(cx: Scope<'a, EditProps<'a>>) -> Element<'a> {
    log::trace!("rendering EditMsg");

    cx.render(rsx!(textarea::Input {
        id: cx.props.id.clone(),
        aria_label: "edit-message-input".into(),
        ignore_focus: false,
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

#[derive(Props, PartialEq)]
pub struct ChatMessageProps {
    text: String,
    remote: bool,
    pending: bool,
    markdown: bool,
    ascii_emoji: bool,
}

#[allow(non_snake_case)]
pub fn ChatText(cx: Scope<ChatMessageProps>) -> Element {
    let mut formatted_text = format_text(&cx.props.text, cx.props.markdown, cx.props.ascii_emoji);
    formatted_text = wrap_links_with_a_tags(&formatted_text);

    let finder = LinkFinder::new();
    let links: Vec<String> = finder
        .spans(&formatted_text)
        .filter(|e| matches!(e.kind(), Some(LinkKind::Url)))
        .map(|e| e.as_str().to_string())
        .collect();

    // this is broken. may be fixed later.
    let _texts = finder.spans(&formatted_text).map(|e| match e.kind() {
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

    let text_type_class = if cx.props.pending {
        "pending-text"
    } else {
        "text"
    };

    cx.render(rsx!(
        div {
            class: text_type_class,
            p {
                class: text_type_class,
                aria_label: "message-text",
                dangerous_inner_html: "{formatted_text}",
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

pub fn format_text(text: &str, should_markdown: bool, should_replace_ascii_emojis: bool) -> String {
    let maybe_marked_down = if should_markdown {
        let (mut text, indices) = markdowns::text_to_html(text);
        if should_replace_ascii_emojis {
            for Range { start, end } in indices {
                let replaced = replace_emojis(&text[start..end]);
                text.replace_range(start..end, &replaced);
            }
        }
        text
    } else if should_replace_ascii_emojis {
        replace_emojis(text)
    } else {
        text.to_string()
    };
    if is_only_emojis(&maybe_marked_down) {
        format!("<span class=\"big-emoji\">{maybe_marked_down}</span>")
    } else {
        format!("<p>{maybe_marked_down}</p>",)
    }
}

use unic_emoji_char::{
    is_emoji, is_emoji_component, is_emoji_modifier, is_emoji_modifier_base, is_emoji_presentation,
};

// if this has to be changed, don't want to have to rewrite the unit tests
fn is_only_emojis(input: &str) -> bool {
    let input = input.trim();
    let mut indices = unic_segment::GraphemeIndices::new(input);
    indices.all(|(_, grapheme)| {
        grapheme.trim().chars().all(|c| {
            is_emoji(c)
                || is_emoji_component(c)
                || is_emoji_modifier(c)
                || is_emoji_modifier_base(c)
                || is_emoji_presentation(c)
                // some emojis are multiple emojis joined by this character
                || c == '\u{200d}'
                // failsafe
                || emojis::get(&String::from(c)).is_some()
        })
    })
}

pub fn replace_emojis(input: &str) -> String {
    fn process_stack<'a>(stack: &'a str) -> &'a str {
        match stack {
            "<3" => "❤️",
            ">:)" => "😈",
            ">:(" => "😠",
            ":)" => "🙂",
            ":(" => " 🙁",
            ":/" => "🫤",
            ";)" => "😉",
            ":D" => "😁",
            "xD" => "😆",
            ":p" | ":P" => "😛",
            ";p" | ";P" => "😜",
            "xP" => "😝",
            ":|" => "😐",
            ":O" => "😮",
            _ => stack,
        }
    }

    let mut builder = String::new();
    let mut stack = String::new();

    for char in input.chars() {
        match char {
            ' ' => {
                builder += process_stack(&stack);
                stack.clear();
                builder.push(char);
            }
            _ => stack.push(char),
        }
    }

    builder += process_stack(&stack);
    builder
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn replace_emojis_test1() {
        let input = ":)";
        let expected = "🙂";
        assert_eq!(&replace_emojis(input), expected);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // too lazy to change the unit tests
    fn transform_only_emoji(input: &str) -> String {
        if is_only_emojis(input) {
            format!("<span class=\"single-emoji\">{}</span>", input.trim())
        } else {
            input.trim().to_string()
        }
    }

    #[test]
    fn test_single_no_emoji() {
        let input = "abc";
        let expected = "abc";
        assert_eq!(&transform_only_emoji(input), expected);
    }

    #[test]
    fn test_single_emoji() {
        let input = "😮";
        let expected = "<span class=\"single-emoji\">😮</span>";
        assert_eq!(&transform_only_emoji(input), expected);
    }

    #[test]
    fn test_single_emoji2() {
        let input = "😮  ";
        let expected = "<span class=\"single-emoji\">😮</span>";
        assert_eq!(&transform_only_emoji(input), expected);
    }

    #[test]
    fn test_triple_emoji() {
        let input = "😮😮👨‍👩‍👦‍👦";
        let expected = "<span class=\"single-emoji\">😮😮👨‍👩‍👦‍👦</span>";
        assert_eq!(&transform_only_emoji(input), expected);
    }

    #[test]
    fn test_multiple_emoji() {
        let input = "🤓😎🥸🤓";
        let expected = "<span class=\"single-emoji\">🤓😎🥸🤓</span>";
        assert_eq!(&transform_only_emoji(input), expected);
    }

    #[test]
    fn test_multiple_emoji2() {
        let input = "🤓😎🤓🤓";
        let expected = "<span class=\"single-emoji\">🤓😎🤓🤓</span>";
        assert_eq!(&transform_only_emoji(input), expected);
    }

    #[test]
    fn test_double_emoji_with_space() {
        let input = "😮 😮";
        let expected = "<span class=\"single-emoji\">😮 😮</span>";
        assert_eq!(&transform_only_emoji(input), expected);
    }

    #[test]
    fn test_comples_emoji() {
        let input = "👨‍👩‍👦‍👦";
        let expected = "<span class=\"single-emoji\">👨‍👩‍👦‍👦</span>";
        assert_eq!(&transform_only_emoji(input), expected);
    }

    #[test]
    fn test_emoji_and_words() {
        let input = "👨‍👩‍👦‍👦abc";
        let expected = "👨‍👩‍👦‍👦abc";
        assert_eq!(&transform_only_emoji(input), expected);
    }
}
