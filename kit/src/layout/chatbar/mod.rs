use dioxus::prelude::*;
use dioxus_elements::input_data::keyboard_types::Code;
use warp::constellation::file::File;

use crate::{
    components::{
        embeds::file_embed::FileEmbed, message::format_text, message_typing::MessageTyping,
    },
    elements::{button::Button, label::Label, textarea, Appearance},
};

use common::{icons, language::get_local_text, warp_runner::thumbnail_to_base64};

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
    id: String,
    placeholder: String,
    typing_users: Vec<String>,
    with_replying_to: Option<Element<'a>>,
    with_file_upload: Option<Element<'a>>,
    extensions: Option<Element<'a>>,
    controls: Option<Element<'a>>,
    value: Option<String>,
    loading: Option<bool>,
    onchange: EventHandler<'a, String>,
    onkeydown: Option<EventHandler<'a, Event<KeyboardData>>>,
    onreturn: EventHandler<'a, String>,
    #[props(default = false)]
    is_disabled: bool,
    ignore_focus: bool,
    emoji_suggestions: &'a Vec<(String, String)>,
    oncursor_update: Option<EventHandler<'a, (String, i64)>>,
    on_emoji_click: Option<EventHandler<'a, (String, String, i64)>>,
}

#[derive(Props)]
pub struct ReplyProps<'a> {
    label: String,
    remote: Option<bool>,
    message: String,
    attachments: Option<Vec<File>>,
    onclose: EventHandler<'a>,
    children: Element<'a>,
    markdown: Option<bool>,
    transform_ascii_emojis: Option<bool>,
}

#[allow(non_snake_case)]
pub fn Reply<'a>(cx: Scope<'a, ReplyProps<'a>>) -> Element<'a> {
    let remote = cx.props.remote.unwrap_or_default();
    let message = format_text(
        &cx.props.message,
        cx.props.markdown.unwrap_or_default(),
        cx.props.transform_ascii_emojis.unwrap_or_default(),
    );

    let has_attachments = cx
        .props
        .attachments
        .as_ref()
        .map(|v| !v.is_empty())
        .unwrap_or(false);

    let attachment_list = cx.props.attachments.as_ref().map(|vec| {
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
            class: "inline-reply",
            aria_label: "inline-reply",
            Label {
                text: cx.props.label.clone(),
                aria_label: "inline-reply-header".into(),
            },
            Button {
                small: true,
                aria_label: "close-reply".into(),
                appearance: Appearance::Secondary,
                icon: icons::outline::Shape::XMark,
                onpress: move |_| cx.props.onclose.call(()),
            },
            div {
                class: "content",
                aria_label: "content",
                remote.then(|| rsx!(&cx.props.children)),
                p {
                    class: {
                        format_args!("reply-text message {}", if remote { "remote" } else { "" })
                    },
                    aria_label: {
                        format_args!("reply-text-message{}", if remote { "-remote" } else { "" })
                    },
                    dangerous_inner_html: "{message}",
                    has_attachments.then(|| {
                        rsx!(
                            attachment_list.map(|list| {
                                rsx!( list )
                            })
                        )
                    })
                }
                (!remote).then(|| rsx!(&cx.props.children)),
            }

        }
    ))
}

#[allow(non_snake_case)]
pub fn Chatbar<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let controlled_input_id = &cx.props.id;
    let is_typing = !cx.props.typing_users.is_empty();
    let cursor_position = use_ref(cx, || None);
    let selected_emoji: &UseRef<Option<usize>> = use_ref(cx, || None);
    let is_emoji_suggestion_modal_closed: &UseRef<bool> = use_ref(cx, || false);
    let eval = use_eval(cx);

    cx.render(rsx!(
        div {
            class: "chatbar disable-select",
            cx.props.with_replying_to.as_ref(),
            cx.props.with_file_upload.as_ref(),
            div{
                class: "chatbar-group",
                textarea::Input {
                    key: "{controlled_input_id}",
                    id: controlled_input_id.clone(),
                    loading: cx.props.loading.unwrap_or_default(),
                    placeholder: cx.props.placeholder.clone(),
                    ignore_focus: cx.props.ignore_focus,
                    show_char_counter: true,
                    value: if cx.props.is_disabled { get_local_text("messages.loading")} else { cx.props.value.clone().unwrap_or_default()},
                    onkeyup: move |keycode| {
                        if !*is_emoji_suggestion_modal_closed.read() && keycode == Code::Escape {
                            is_emoji_suggestion_modal_closed.with_mut(|i| *i = true);
                        }
                    },
                    onkeydown:  move |keyboard_event: Event<KeyboardData>| {
                        if let Some(e) = cx.props.onkeydown.as_ref() {
                            e.call(keyboard_event);
                        }
                    },
                    onchange: move |(v, _)| {
                        cx.props.onchange.call(v);
                        *is_emoji_suggestion_modal_closed.write_silent() = false;
                    },
                    onreturn: move |(v, is_valid, _)| {
                        if let Some(i) = selected_emoji.write_silent().take() {
                            if let Some(e) = cx.props.on_emoji_click.as_ref() {
                                if let Some(p) = cursor_position.read().as_ref() {
                                    let (emoji, alias) = cx.props.emoji_suggestions[i].clone();
                                    e.call((emoji, alias,*p));
                                    return;
                                }
                            }
                        }
                        if is_valid {
                            cx.props.onreturn.call(v);
                        }
                    },
                    oncursor_update: move |(v,p)| {
                        if let Some(e) = cx.props.oncursor_update.as_ref() {
                            e.call((v,p))
                        }
                        *cursor_position.write_silent() = Some(p)
                    },
                    is_disabled: cx.props.is_disabled,
                    prevent_up_down_arrows: !cx.props.emoji_suggestions.is_empty(),
                    onup_down_arrow:
                        move |code| {
                            if cx.props.emoji_suggestions.is_empty() {
                                *selected_emoji.write_silent() = None;
                                return;
                            }
                            let current = &mut *selected_emoji.write_silent();
                            let amount = cx.props.emoji_suggestions.len();
                            let selected_idx = if code == Code::ArrowDown {
                                match current.as_ref() {
                                    Some(v) => (v + 1) % amount,
                                    None => 0,
                                }
                            } else {
                                match current.as_ref() {
                                    Some(v) => (v + amount - 1) % amount,
                                    None => amount - 1,
                                }
                            };
                            *current = Some(selected_idx);
                            let _ = eval(&include_str!("./emoji_scroll.js").replace("$NUM", &selected_idx.to_string()));
                        }
                },
                is_typing.then(|| {
                    rsx!(MessageTyping {
                        typing_users: cx.props.typing_users.clone()
                    })
                })
            }
            cx.props.extensions.as_ref(),
            div {
                class: "controls",
                cx.props.controls.as_ref()
            },
            (!cx.props.emoji_suggestions.is_empty() && !*is_emoji_suggestion_modal_closed.read()).then(||
                rsx!(EmojiSuggesions {
                suggestions: cx.props.emoji_suggestions,
                on_close: move |_| {
                    is_emoji_suggestion_modal_closed.with_mut(|i| *i = true);
                },
                on_emoji_click: move |(emoji, alias)| {
                    if let Some(e) = cx.props.on_emoji_click.as_ref() {
                        if let Some(p) = cursor_position.read().as_ref() {
                            e.call((emoji, alias, *p))
                        }
                    }
                },
                selected: selected_emoji.clone(),
            })),
        }
    ))
}

#[derive(Props)]
pub struct EmojiSuggestionProps<'a> {
    suggestions: &'a Vec<(String, String)>,
    on_emoji_click: EventHandler<'a, (String, String)>,
    on_close: EventHandler<'a, ()>,
    selected: UseRef<Option<usize>>,
}

#[allow(non_snake_case)]
fn EmojiSuggesions<'a>(cx: Scope<'a, EmojiSuggestionProps<'a>>) -> Element<'a> {
    if cx.props.selected.read().is_none() {
        *cx.props.selected.write_silent() = Some(0);
    }
    cx.render(rsx!(div {
        class: "emoji-suggestions",
        aria_label: "emoji-suggestions-container",
        onmouseenter: move |_| {
            *cx.props.selected.write() = None;
        },
        onmouseleave: move |_| {
            *cx.props.selected.write() = None;
        },
        Button {
            small: true,
            aria_label: "emoji-suggestion-close-button".into(),
            appearance: Appearance::Secondary,
            icon: icons::outline::Shape::XMark,
            onpress: move |_| cx.props.on_close.call(()),
        },
        div {
            class: "emoji-suggestions-header",
            Label {
                text: get_local_text("messages.suggested-emoji"),
            },
        }
        cx.props.suggestions.iter().enumerate().map(|(num, (emoji,alias))| {
            cx.render(rsx!(div {
                class: format_args!("{} {}", "emoji-suggestion", match cx.props.selected.read().as_ref() {
                    Some(v) => if *v == num {"emoji-selected"} else {""},
                    None => "",
                }),
                aria_label: {
                    format_args!(
                        "emoji-suggested-{emoji}",
                    )
                },
                onclick: move |_| {
                    cx.props.on_emoji_click.call((emoji.clone(), alias.clone()))
                },
                format_args!("{emoji}  :{alias}:"),
            }))
        })
    }))
}
