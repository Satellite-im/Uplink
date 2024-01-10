use std::path::PathBuf;
use std::{collections::HashSet, str::FromStr};

use common::language::{get_local_text, get_local_text_with_args};
use common::state::{Action, Identity, State, ToastNotification};
use common::warp_runner::{thumbnail_to_base64, MultiPassCmd, WarpCmd};
use common::{state::pending_message::progress_file, WARP_CMD_CH};
//use common::icons::outline::Shape as Icon;
use arboard::Clipboard;
use derive_more::Display;
use dioxus::prelude::*;
use futures::StreamExt;
use linkify::{LinkFinder, LinkKind};
use once_cell::sync::Lazy;
use pulldown_cmark::{CodeBlockKind, Options, Tag};
use regex::{Captures, Regex, Replacer};
use uuid::Uuid;
use warp::error::Error;
use warp::{
    constellation::{file::File, Progression},
    crypto::DID,
    logging::tracing::log,
};

use common::icons::outline::Shape as Icon;

use crate::components::context_menu::{ContextItem, ContextMenu, IdentityHeader};
use crate::elements::button::Button;
use crate::{components::embeds::file_embed::FileEmbed, elements::textarea};

use super::embeds::link_embed::EmbedLinks;

pub static MARKDOWN_PROCESSOR_REGEX: Lazy<Regex> =
    Lazy::new(|| Regex::new("(^|\n)((?:&gt;(?: *&gt;)*)|(?: ))").unwrap());
pub static LINK_TAGS_REGEX: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r#"(?i)\b((?:(?:https?://|www\.)[^\s()<>]+|\(([^\s()<>]+|(\([^\s()<>]+\)))*\))+(?:\(([^\s()<>]+|(\([^\s()<>]+\)))*\)|[^\s`!()\[\]{};:'".,<>?«»“”‘’]))"#).unwrap()
});

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

    tagged_text: Option<String>,

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
    on_download: EventHandler<'a, (File, Option<PathBuf>)>,

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
    #[props(!optional)]
    attachments_pending_uploads: Option<&'a Vec<Progression>>,

    pinned: bool,

    is_mention: bool,
}

fn wrap_links_with_a_tags(text: &str) -> String {
    LINK_TAGS_REGEX
        .replace_all(text, |caps: &regex::Captures| {
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
    let rendered_text = cx
        .props
        .tagged_text
        .as_ref()
        .or(cx.props.with_text.as_ref());

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
                on_press: move |temp_dir_option| cx
                    .props
                    .on_download
                    .call((file.clone(), temp_dir_option)),
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
    let mention_class = cx.props.is_mention.then_some("mention").unwrap_or_default();
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
                    "message {} {} {} {} {}",
                   loading_class, remote_class, order_class, msg_pending_class, mention_class
                )
            },
            aria_label: {
                format_args!(
                    "message-{}",
                    if is_remote {
                        "remote"
                    } else { "local" },
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
                    text: rendered_text.cloned().unwrap_or_default(),
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
    participants: Option<Vec<String>>,
}

#[allow(non_snake_case)]
pub fn ChatText(cx: Scope<ChatMessageProps>) -> Element {
    // DID::from_str panics if text is 'z'. simple fix is to ensure string is long enough.
    if cx.props.text.len() > 2 {
        if let Ok(id) = DID::from_str(&cx.props.text) {
            return cx.render(rsx!(IdentityMessage { id: id }));
        }
    }

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

pub fn format_text(text: &str, should_markdown: bool, emojis: bool) -> String {
    // warning: this will probably break markdown regarding block quotes. still seems like an improvement.
    let safe_text = text
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('\"', "&quot;")
        .replace('\'', "&#x27;")
        .replace('\n', "&nbsp;&nbsp;\n");
    let text = &safe_text;
    if should_markdown {
        markdown(text, emojis)
    } else if emojis {
        let s = replace_emojis(text.trim());
        if is_only_emojis(&s) {
            format!("<span class=\"big-emoji\">{s}</span>")
        } else {
            format!("<p>{s}</p>")
        }
    } else {
        format!("<p>{}</p>", text.trim())
    }
}

fn stack_processor(stack: &str, unescape_html: bool, emojis: bool) -> &str {
    if unescape_html {
        match stack {
            "&quot;" => return "\"",
            "&amp;" => return "&",
            "&lt;" => return "<",
            "&gt;" => return ">",
            "&nbsp;" => return " ",
            _ => {}
        }
    }
    if !emojis {
        return stack;
    }
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

pub fn process_string<F>(input: &str, processor: F) -> String
where
    F: Fn(&str) -> &str,
{
    let mut builder = String::new();
    let mut stack = String::new();

    for char in input.chars() {
        match char {
            ' ' => {
                builder += processor(&stack);
                stack.clear();
                builder.push(char);
            }
            _ => stack.push(char),
        }
    }

    builder += processor(&stack);
    builder
}

pub fn replace_emojis(input: &str) -> String {
    process_string(input, |s| stack_processor(s, false, true))
}

struct RegexReplacer;

impl Replacer for RegexReplacer {
    fn replace_append(&mut self, caps: &Captures<'_>, dst: &mut String) {
        dst.push_str(&caps[1]);
        if caps[2].eq(" ") {
            dst.push_str("&nbsp;");
        } else {
            dst.push_str(&caps[2].replace("&gt;", ">"));
        }
    }
}

fn markdown(text: &str, emojis: bool) -> String {
    let txt = text.trim();
    if emojis {
        let r = replace_emojis(txt);
        // TODO: Watch this issue for a fix: https://github.com/open-i18n/rust-unic/issues/280
        // This is a temporary workaround for some characters unic-emoji-char thinks are emojis
        if !r.chars().all(char::is_alphanumeric) // for any numbers, eg 1, 11, 111
           && r != "#"
           && r != "*"
           && r != "##"
           && r != "**"
           && r != "-"
           && is_only_emojis(&r)
        {
            return format!("<span class=\"big-emoji\">{r}</span>");
        } else if is_only_emojis(txt) || r == "-" {
            return format!("<p>{txt}</p>");
        }
    }

    let mut options = Options::empty();
    options.insert(Options::ENABLE_STRIKETHROUGH);

    let text = MARKDOWN_PROCESSOR_REGEX.replace_all(txt, RegexReplacer);

    let mut html_output = String::new();
    let mut in_paragraph = false;
    let mut in_code_block = false;

    let parser = pulldown_cmark::Parser::new_ext(&text, options);
    for event in parser {
        match event {
            pulldown_cmark::Event::Start(pulldown_cmark::Tag::CodeBlock(
                CodeBlockKind::Indented,
            )) => {
                html_output.push_str("</p>\n<p> </p><p>");
            }
            pulldown_cmark::Event::End(pulldown_cmark::Tag::CodeBlock(CodeBlockKind::Indented)) => {
            }
            pulldown_cmark::Event::SoftBreak => {
                if in_paragraph {
                    html_output.push_str("</p>\n<p>");
                }
            }
            pulldown_cmark::Event::Start(Tag::Paragraph) => {
                in_paragraph = true;
                html_output.push_str("<p>");
            }
            pulldown_cmark::Event::End(Tag::Paragraph) => {
                in_paragraph = false;
            }
            pulldown_cmark::Event::Text(t) => {
                let text = if emojis || in_code_block {
                    process_string(&t, |s| stack_processor(s, in_code_block, emojis))
                } else {
                    t.to_string()
                };
                let txt: pulldown_cmark::CowStr<'_> = if in_paragraph {
                    text.replace("\n\n", "<br/>").into()
                } else {
                    text.into()
                };
                if in_code_block {
                    html_output.push_str(&txt);
                } else {
                    pulldown_cmark::html::push_html(
                        &mut html_output,
                        std::iter::once(pulldown_cmark::Event::Text(txt)),
                    );
                }
            }
            event => {
                match event {
                    pulldown_cmark::Event::Start(pulldown_cmark::Tag::CodeBlock(_)) => {
                        in_code_block = true;
                    }
                    pulldown_cmark::Event::End(pulldown_cmark::Tag::CodeBlock(_)) => {
                        in_code_block = false;
                    }
                    _ => {}
                }
                pulldown_cmark::html::push_html(&mut html_output, std::iter::once(event))
            }
        }
    }
    html_output.push('\n');
    html_output
}

#[derive(Display)]
pub enum IdentityCmd {
    #[display(fmt = "GetIdentity")]
    GetIdentity(DID),
    #[display(fmt = "SentFriendRequest")]
    SentFriendRequest(String, Vec<Identity>),
}

#[derive(Props, PartialEq)]
pub struct IdentityMessageProps {
    id: DID,
}

#[allow(non_snake_case)]
pub fn IdentityMessage(cx: Scope<IdentityMessageProps>) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let identity = use_state(cx, || None);
    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<IdentityCmd>| {
        to_owned![identity, state];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(cmd) = rx.next().await {
                match cmd {
                    IdentityCmd::GetIdentity(id) => {
                        let (tx, rx) = futures::channel::oneshot::channel();
                        let _ = warp_cmd_tx.send(WarpCmd::MultiPass(MultiPassCmd::GetIdentity {
                            did: id,
                            rsp: tx,
                        }));
                        let r = rx.await.expect("no identity found");
                        if let Ok(id) = r {
                            identity.set(Some(id));
                        }
                    }
                    IdentityCmd::SentFriendRequest(id, outgoing_requests) => {
                        let (tx, rx) = futures::channel::oneshot::channel();
                        let _ = warp_cmd_tx.send(WarpCmd::MultiPass(MultiPassCmd::RequestFriend {
                            id,
                            outgoing_requests,
                            rsp: tx,
                        }));
                        let res = rx.await.expect("failed to get response from warp_runner");
                        match res {
                            Ok(_) => {}
                            Err(e) => match e {
                                Error::PublicKeyIsBlocked => {
                                    log::warn!("add friend failed: {}", e);
                                    state.write().mutate(Action::AddToastNotification(
                                        ToastNotification::init(
                                            "".into(),
                                            get_local_text("friends.key-blocked"),
                                            None,
                                            2,
                                        ),
                                    ));
                                }
                                _ => {
                                    //The other errors are covered by button already
                                    log::error!("add friend failed: {}", e);
                                    state.write().mutate(Action::AddToastNotification(
                                        ToastNotification::init(
                                            "".into(),
                                            get_local_text("friends.add-failed"),
                                            None,
                                            2,
                                        ),
                                    ));
                                }
                            },
                        }
                    }
                }
            }
        }
    });
    use_effect(cx, &cx.props.id, |id| {
        to_owned![ch];
        async move {
            ch.send(IdentityCmd::GetIdentity(id));
        }
    });
    match identity.as_ref() {
        Some(identity) => {
            let disabled = state
                .read()
                .outgoing_fr_identities()
                .iter()
                .any(|req| req.did_key().eq(&identity.did_key()))
                || state
                    .read()
                    .get_own_identity()
                    .did_key()
                    .eq(&identity.did_key())
                || state
                    .read()
                    .friend_identities()
                    .iter()
                    .any(|req| req.did_key().eq(&identity.did_key()));

            let short_id = identity.short_id();
            let did_key = identity.did_key();
            let username = identity.username();
            let short_name = format!("{}#{}", username, short_id);
            let random_uuid = Uuid::new_v4().to_string();

            return cx.render(rsx!(
                ContextMenu {
                    key: "{short_id}-{random_uuid}",
                    id: format!("{short_id}-{random_uuid}"),
                    devmode: state.read().configuration.developer.developer_mode,
                    items: cx.render(rsx!(
                        ContextItem {
                            icon: Icon::UserCircle,
                            aria_label: "copy-user-id-from-user-identity-on-chat".into(),
                            text: get_local_text("settings-profile.copy-id"),
                            onpress: move |_| {
                                match Clipboard::new() {
                                    Ok(mut c) => {
                                        if let Err(e) = c.set_text(short_name.clone()) {
                                            log::warn!("Unable to set text to clipboard: {e}");
                                        }
                                    },
                                    Err(e) => {
                                        log::warn!("Unable to create clipboard reference: {e}");
                                    }
                                };
                                state
                                    .write()
                                    .mutate(Action::AddToastNotification(ToastNotification::init(
                                        "".into(),
                                        get_local_text("friends.copied-did"),
                                        None,
                                        2,
                                    )));
                            }
                        },
                        ContextItem {
                            icon: Icon::Key,
                            aria_label: "copy-user-did-key-from-user-identity-on-chat".into(),
                            disabled: false,
                            text: get_local_text("settings-profile.copy-did"),
                            onpress: move |_| {
                                match Clipboard::new() {
                                    Ok(mut c) => {
                                        if let Err(e) = c.set_text(did_key.to_string()) {
                                            log::warn!("Unable to set text to clipboard: {e}");
                                        }
                                    },
                                    Err(e) => {
                                        log::warn!("Unable to create clipboard reference: {e}");
                                    }
                                };
                                state
                                    .write()
                                    .mutate(Action::AddToastNotification(ToastNotification::init(
                                        "".into(),
                                        get_local_text("friends.copied-did"),
                                        None,
                                        2,
                                    )));
                            },
                            tooltip: None,
                        }
                    )),
                   children: cx.render(rsx!(div { // TODO: This needs to be moved to kit/src/components/embeds/identity_embed/mod.rs.
                        class: "embed-identity",
                        IdentityHeader {
                            sender_did: identity.did_key(),
                            with_status: false,
                        },
                        div {
                            class: "profile-container",
                            div {
                                id: "profile-name",
                                aria_label: "profile-name",
                                p {
                                    class: "text",
                                    aria_label: "profile-name-value",
                                    format!("{}", identity.username())
                                }
                            }
                            identity.status_message().and_then(|s|{
                                cx.render(rsx!(
                                    div {
                                        id: "profile-status",
                                        aria_label: "profile-status",
                                        p {
                                            class: "text",
                                            aria_label: "profile-status-value",
                                            s
                                        }
                                    }
                                ))
                            }),
                        },
                        Button {
                            aria_label: String::from("embed-identity-button"),
                            disabled: disabled,
                            with_title: false,
                            onpress: move |_| {
                                ch.send(IdentityCmd::SentFriendRequest(identity.did_key().to_string(), state.read().outgoing_fr_identities()));
                            },
                            icon: if disabled {
                                Icon::Check
                            } else {
                                Icon::Plus
                            },
                            text: if disabled {
                                get_local_text("friends.already-friends")
                            } else {
                                get_local_text_with_args("friends.add-name", vec![("name", identity.username())])
                            },
                            appearance: crate::elements::Appearance::Primary
                        }
                    }))
                }
            ));
        }
        None => {
            return cx.render(rsx!(div {
                class: "embed-identity",
                div {
                    class: "profile-container empty-profile",
                    div {
                        class: "unknown-user",
                        aria_label: "unknown-user",
                        p {
                            class: "text",
                            aria_label: "unknown-user-value",
                            get_local_text("messages.unknown-identity")
                        }
                    },
                    div {
                        id: "unknown-user-did",
                        aria_label: "unknown-user-did",
                        p {
                            class: "text",
                            aria_label: "unknown-user-did-value",
                            cx.props.id.to_string()
                        }
                    }
                }
            }))
        }
    }
}

use unic_emoji_char::{
    is_emoji, is_emoji_component, is_emoji_modifier, is_emoji_modifier_base, is_emoji_presentation,
};

// matches strings conssisting of emojis and whitespace
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
mod tests2 {
    use super::*;

    #[test]
    fn test_format_text1() {
        let input = ":) ";
        let expected = "<span class=\"big-emoji\">🙂</span>";
        assert_eq!(&format_text(input, true, true), expected);
        assert_eq!(&format_text(input, false, true), expected);
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
    fn test_single_emoji3() {
        let input = "👍🏾  ";
        let expected = "<span class=\"single-emoji\">👍🏾</span>";
        assert_eq!(&transform_only_emoji(input), expected);
    }

    #[test]
    fn test_single_emoji4() {
        let input = "🙂";
        let expected = "<span class=\"single-emoji\">🙂</span>";
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
        let input = "🤓😎🥸🤓 🙂";
        let expected = "<span class=\"single-emoji\">🤓😎🥸🤓 🙂</span>";
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
