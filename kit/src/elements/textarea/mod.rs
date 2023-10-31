//! This was made for the chatbar but it turns out that a contenteditable div is needed to render markdown. This is a temporary solution.
//! this could be merged with kit/src/elements/input and make the input element use a textarea based on a property.
//! that might helpful if a textarea needed to perform input validation.

use dioxus::prelude::*;
use dioxus_html::input_data::keyboard_types::Code;
use pulldown_cmark::{CodeBlockKind, Options, Tag};
use uuid::Uuid;
use warp::logging::tracing::log;

use crate::components::message::STRIKE_THROUGH_REGEX;

#[derive(Clone, Copy)]
pub enum Size {
    Small,
    Normal,
}

impl Size {
    fn get_height(&self) -> &str {
        match self {
            Size::Small => "0",
            _ => "",
        }
    }
}

#[derive(Props)]
pub struct Props<'a> {
    #[props(default = "".to_owned())]
    id: String,
    #[props(default = false)]
    ignore_focus: bool,
    #[props(default = false)]
    loading: bool,
    #[props(default = "".to_owned())]
    placeholder: String,
    #[props(default = 1025)]
    max_length: i32,
    #[props(default = Size::Normal)]
    size: Size,
    #[props(default = "".to_owned())]
    aria_label: String,
    onchange: EventHandler<'a, (String, bool)>,
    onreturn: EventHandler<'a, (String, bool, Code)>,
    oncursor_update: Option<EventHandler<'a, (String, i64)>>,
    value: String,
    #[props(default = false)]
    is_disabled: bool,
    #[props(default = false)]
    show_char_counter: bool,
    #[props(default = false)]
    prevent_up_down_arrows: bool,
    onup_down_arrow: Option<EventHandler<'a, Code>>,
    with_highlight: Option<bool>,
}

#[allow(non_snake_case)]
pub fn Input<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    log::trace!("render input");
    let eval = use_eval(cx);
    let left_shift_pressed = use_ref(cx, || false);
    let right_shift_pressed = use_ref(cx, || false);
    let enter_pressed = use_ref(cx, || false);
    let numpad_enter_pressed = use_ref(cx, || false);
    let cursor_position = use_ref(cx, || None);

    let Props {
        id: _,
        ignore_focus: _,
        loading,
        placeholder,
        max_length,
        size,
        aria_label,
        onchange,
        onreturn,
        oncursor_update,
        value,
        is_disabled,
        show_char_counter,
        prevent_up_down_arrows,
        onup_down_arrow,
        with_highlight,
    } = &cx.props;

    let with_highlight = with_highlight.unwrap_or_default();

    let id = if cx.props.id.is_empty() {
        Uuid::new_v4().to_string()
    } else {
        cx.props.id.clone()
    };
    let id2 = id.clone();
    let id3 = id.clone();
    let id_char_counter = id.clone();
    let focus_script = if cx.props.ignore_focus {
        String::new()
    } else {
        include_str!("./focus.js").replace("$UUID", &id)
    };

    let _ = eval(&focus_script);

    let script = include_str!("./script.js")
        .replace("$UUID", &id)
        .replace("$MULTI_LINE", &format!("{}", true));
    let disabled = *loading || *is_disabled;

    let on_input_update = include_str!("./on_input_update.js").replace("$UUID", &id);
    let clear_counter_script =
        r#"document.getElementById('$UUID-char-counter').innerText = "0";"#.replace("$UUID", &id);

    let cursor_script = include_str!("./cursor_script.js").replace("$ID", &id2);

    let text_value = use_ref(cx, || value.clone());
    use_future(cx, value, |val| {
        to_owned![cursor_position, text_value, eval];
        async move {
            *cursor_position.write_silent() = Some(val.chars().count() as i64);
            *text_value.write_silent() = val;
            let _ = eval(&on_input_update.replace("$TEXT", &text_value.read()));
        }
    });

    let do_cursor_update = oncursor_update.is_some();

    if let Some(val) = cursor_position.write_silent().take() {
        if let Some(e) = oncursor_update {
            e.call((text_value.read().clone(), val));
        }
    }

    cx.render(rsx! (
        div {
            id: "input-group-{id}",
            class: "input-group",
            aria_label: "input-group",
            div {
                class: format_args!("input {}", if disabled { "disabled" } else { " " }),
                height: "{size.get_height()}",
                textarea {
                    key: "textarea-key-{id}",
                    class: format_args!("{} {} {}", "input_textarea", if *prevent_up_down_arrows {"up-down-disabled"} else {""}, if with_highlight {"text-area-highlight"} else {""}),
                    id: "{id}",
                    aria_label: "{aria_label}",
                    disabled: "{disabled}",
                    value: "{text_value.read()}",
                    maxlength: "{max_length}",
                    placeholder: format_args!("{}", if *is_disabled {""} else {placeholder}),
                    onblur: move |_| {
                        onreturn.call((text_value.read().to_string(), false, Code::Enter));
                    },
                    oninput: {
                        to_owned![eval, cursor_script];
                        move |evt| {
                            let current_val = evt.value.clone();
                            *text_value.write_silent() = current_val.clone();
                            onchange.call((current_val, true));
                            to_owned![eval, cursor_script, cursor_position];
                            async move {
                                if do_cursor_update {
                                    if let Ok(r) = eval(&cursor_script) {
                                        if let Ok(val) = r.join().await {
                                            *cursor_position.write() = Some(val.as_i64().unwrap_or_default());
                                        }
                                    }
                                }
                            }
                        }
                    },
                    onkeyup: move |evt| {
                        match evt.code() {
                            Code::ShiftLeft => *left_shift_pressed.write_silent() = false,
                            Code::ShiftRight => *right_shift_pressed.write_silent() = false,
                            Code::Enter => *enter_pressed.write_silent() = false,
                            Code::NumpadEnter => *numpad_enter_pressed.write_silent() = false,
                            _ => {}
                        };
                    },
                    onmousedown: {
                        to_owned![eval, cursor_script];
                        move |_| {
                            to_owned![eval, cursor_script, cursor_position];
                            async move {
                                if do_cursor_update {
                                    if let Ok(r) = eval(&cursor_script) {
                                        if let Ok(val) = r.join().await {
                                            *cursor_position.write() = Some(val.as_i64().unwrap_or_default());
                                        }
                                    }
                                }
                            }
                        }
                    },
                    onkeydown: {
                        to_owned![eval, cursor_script];
                        move |evt| {
                            // special codepath to handle onreturn
                            let old_enter_pressed = *enter_pressed.read();
                            let old_numpad_enter_pressed = *numpad_enter_pressed.read();
                            match evt.code() {
                                Code::ShiftLeft => if !*left_shift_pressed.read() { *left_shift_pressed.write_silent() = true; },
                                Code::ShiftRight => if !*right_shift_pressed.read() { *right_shift_pressed.write_silent() = true; },
                                Code::Enter => if !*enter_pressed.read() { *enter_pressed.write_silent() = true; } ,
                                Code::NumpadEnter => if !*numpad_enter_pressed.read() { *numpad_enter_pressed.write_silent() = true; },
                                _ => {}
                            };
                            // write_silent() doesn't update immediately. if the enter key is pressed, have to check the evt code
                            let enter_toggled = !old_enter_pressed && matches!(evt.code(), Code::Enter);
                            let numpad_enter_toggled = !old_numpad_enter_pressed && matches!(evt.code(), Code::NumpadEnter);
                            if (enter_toggled || numpad_enter_toggled) && !(*right_shift_pressed.read() || *left_shift_pressed.read())
                            {
                                 if *show_char_counter {
                                        let _ = eval(&clear_counter_script);
                                    }
                                    onreturn.call((text_value.read().clone(), true, evt.code()));
                            }

                            // special codepath to handle the arrow keys
                            let arrow = match evt.code() {
                                Code::ArrowDown|Code::ArrowUp => {
                                    if let Some(e) = onup_down_arrow {
                                        e.call(evt.code());
                                    };
                                    true
                                }
                                Code::ArrowLeft|Code::ArrowRight => {
                                    true
                                }
                                _ => {
                                    false
                                }
                            };
                            to_owned![eval, cursor_script, cursor_position];
                            async move {
                                if do_cursor_update && arrow {
                                    if let Ok(r) = eval(&cursor_script) {
                                        if let Ok(val) = r.join().await {
                                            *cursor_position.write() = Some(val.as_i64().unwrap_or_default());
                                        }
                                    }
                                }
                            }
                        }
                    }
                },
                //This kinda works. 
                // But needs 1. adding the stripped formatting symbols like ``` back
                // 2. Does not work if using bold...
                with_highlight.then(||{
                    rsx!(pre {
                        class: "textarea-styled",
                        id: "{id3}-styled-text",
                        dangerous_inner_html: format_args!("{}", syntax_highlight(&text_value.read()))
                    })
                }),
                if *show_char_counter {
                    rsx!(
                        div {
                            class: "input-char-counter",
                            p {
                                key: "{id_char_counter}-char-counter",
                                id: "{id_char_counter}-char-counter",
                                aria_label: "input-char-counter",
                                class: "char-counter-p-element",
                                format!("{}", text_value.read().len()),
                            },
                            p {
                                key: "{id_char_counter}-char-max-length",
                                id: "{id_char_counter}-char-max-length",
                                class: "char-counter-p-element",
                                format!("/{}", max_length - 1),
                            }
                        }
                        )
                }
            },
        }
        script { script },
        script { focus_script }
    ))
}

// Like the one for messages in message::markdown. But tweaked a bit
pub fn syntax_highlight(text: &str) -> String {
    let mut options = Options::empty();
    options.insert(Options::ENABLE_STRIKETHROUGH);
    let modified_lines: Vec<String> = text
        .split('\n')
        .map(|line| {
            // For strikethrough to be fully detected they need leading and trailing whitespaces
            let line = STRIKE_THROUGH_REGEX.replace_all(line, " $1 ");
            if line.starts_with('>') {
                format!("\\{}", line)
            } else {
                line.to_string()
            }
        })
        .collect();

    let mut modified_lines_refs: Vec<&str> = modified_lines.iter().map(|s| s.as_str()).collect();
    //if text.ends_with("\n") {
    //    modified_lines_refs.push(" ");
    //}
    let mut html_output = String::new();
    let mut in_paragraph = false;
    let mut in_code_block = false;
    let mut add_text_language = true;

    for line in &mut modified_lines_refs {
        if line.is_empty() {
            html_output.push_str("<p> </p>");
            continue;
        }
        let parser = pulldown_cmark::Parser::new_ext(line, options);
        let line_trim = line.trim();
        if line_trim == "```" && add_text_language {
            *line = "```text";
            add_text_language = false;
        }
        let mut it = parser.into_iter().peekable();
        let mut previous_event = None;
        while let Some(event) = it.next() {
            let prev = event.clone();
            match event {
                pulldown_cmark::Event::Start(Tag::Paragraph) => {
                    in_paragraph = true;
                    html_output.push_str("<p>");
                }
                pulldown_cmark::Event::End(Tag::Paragraph) => {
                    in_paragraph = false;
                }
                pulldown_cmark::Event::Text(t) => {
                    // Remove the one leading/trailing whitespace from strikethrough processing
                    let text = if let Some(pulldown_cmark::Event::End(Tag::Strikethrough)) =
                        previous_event
                    {
                        t.strip_prefix(' ').unwrap_or(&t).into()
                    } else if let Some(&pulldown_cmark::Event::Start(Tag::Strikethrough)) =
                        it.peek()
                    {
                        t.strip_suffix(' ').unwrap_or(&t).into()
                    } else {
                        t.to_string()
                    };
                    let txt: pulldown_cmark::CowStr<'_> = if in_paragraph {
                        text.replace("\n\n", "<br/>").into()
                    } else {
                        text.into()
                    };
                    pulldown_cmark::html::push_html(
                        &mut html_output,
                        std::iter::once(pulldown_cmark::Event::Text(txt)),
                    );
                }
                pulldown_cmark::Event::Start(pulldown_cmark::Tag::CodeBlock(code_block_kind)) => {
                    add_text_language = false;
                    match code_block_kind {
                        CodeBlockKind::Fenced(language_o) => {
                            let language = if language_o.is_empty() {
                                "text"
                            } else {
                                &language_o
                            };
                            html_output
                                .push_str(&format!("<pre><code class=\"language-{}\">", language));
                            if !in_code_block && !language_o.is_empty() {
                                html_output.push_str(&format!(
                                    "<p>```{}",
                                    if language_o.is_empty() {
                                        ""
                                    } else {
                                        &language_o
                                    }
                                ));
                            }
                        }
                        _ => html_output.push_str("<pre><code class=\"language-text\">"),
                    };
                    in_code_block = true;
                }
                pulldown_cmark::Event::End(pulldown_cmark::Tag::CodeBlock(_)) => {
                    if in_code_block && line_trim == "```" {
                        in_code_block = false;
                        add_text_language = true;
                        // HACK: To close block code is necessary to push tags 2 times
                        html_output.push_str("</code></pre>");
                        html_output.push_str("<p>```");
                        html_output.push_str("</code></pre>");
                    }
                }
                pulldown_cmark::Event::Code(txt) => {
                    html_output.push_str("`");
                    pulldown_cmark::html::push_html(
                        &mut html_output,
                        std::iter::once(pulldown_cmark::Event::Code(txt)),
                    );
                    html_output.push_str("`");
                }
                pulldown_cmark::Event::Start(tag) => match tag {
                    // Add back removed markdown formatting symbols. Also since bold doesn't work properly disable it
                    Tag::List(opt) => html_output.push_str(
                        &opt.map(|i| format!("<p>{}. ", i))
                            .unwrap_or(String::from("<p>*")),
                    ),
                    Tag::Item => {}
                    Tag::Emphasis => html_output.push_str("*<em>"),
                    Tag::Strong => html_output.push_str("**"),
                    Tag::Strikethrough => html_output.push_str("~~<del>"),
                    _ => pulldown_cmark::html::push_html(
                        &mut html_output,
                        std::iter::once(pulldown_cmark::Event::Start(tag)),
                    ),
                },
                pulldown_cmark::Event::End(tag) => match tag {
                    Tag::List(_) => html_output.push_str("</p>"),
                    Tag::Item => {}
                    Tag::Emphasis => html_output.push_str("</em>*"),
                    Tag::Strong => html_output.push_str("**"),
                    Tag::Strikethrough => html_output.push_str("</del>~~"),
                    _ => pulldown_cmark::html::push_html(
                        &mut html_output,
                        std::iter::once(pulldown_cmark::Event::Start(tag)),
                    ),
                },
                _ => pulldown_cmark::html::push_html(&mut html_output, std::iter::once(event)),
            }
            previous_event = Some(prev);
        }
    }
    html_output
}

// Attempt using plain div
pub fn Input2<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    log::trace!("render input");
    let eval = use_eval(cx);
    let left_shift_pressed = use_ref(cx, || false);
    let right_shift_pressed = use_ref(cx, || false);
    let enter_pressed = use_ref(cx, || false);
    let numpad_enter_pressed = use_ref(cx, || false);
    let cursor_position = use_ref(cx, || None);

    let Props {
        id: _,
        ignore_focus: _,
        loading,
        placeholder,
        max_length,
        size,
        aria_label,
        onchange,
        onreturn,
        oncursor_update,
        value,
        is_disabled,
        show_char_counter,
        prevent_up_down_arrows,
        onup_down_arrow,
        with_highlight,
    } = &cx.props;

    let with_highlight = with_highlight.unwrap_or_default();

    let id = if cx.props.id.is_empty() {
        Uuid::new_v4().to_string()
    } else {
        cx.props.id.clone()
    };
    let id2 = id.clone();
    let id3 = id.clone();
    let id_char_counter = id.clone();
    let focus_script = if cx.props.ignore_focus {
        String::new()
    } else {
        include_str!("./focus.js").replace("$UUID", &id)
    };

    let _ = eval(&focus_script);

    let script = include_str!("./script.js")
        .replace("$UUID", &id)
        .replace("$MULTI_LINE", &format!("{}", true));
    let disabled = *loading || *is_disabled;

    let on_input_update = include_str!("./on_input_update.js").replace("$UUID", &id);
    let clear_counter_script =
        r#"document.getElementById('$UUID-char-counter').innerText = "0";"#.replace("$UUID", &id);

    let cursor_script = include_str!("./cursor_script.js").replace("$ID", &id2);

    let text_value = use_ref(cx, || value.clone());
    use_future(cx, value, |val| {
        to_owned![cursor_position, text_value, eval];
        async move {
            *cursor_position.write_silent() = Some(val.chars().count() as i64);
            *text_value.write_silent() = val;
            let _ = eval(&on_input_update.replace("$TEXT", &text_value.read()));
        }
    });

    let do_cursor_update = oncursor_update.is_some();

    if let Some(val) = cursor_position.write_silent().take() {
        if let Some(e) = oncursor_update {
            e.call((text_value.read().clone(), val));
        }
    }

    cx.render(rsx! (
        div {
            id: "input-group-{id}",
            class: "input-group",
            aria_label: "input-group",
            div {
                class: format_args!("input {}", if disabled { "disabled" } else { " " }),
                height: "{size.get_height()}",
                div {
                    key: "textarea-key-{id}",
                    class: format_args!("{} {} {}", "input_textarea", if *prevent_up_down_arrows {"up-down-disabled"} else {""}, if with_highlight {"text-area-highlight"} else {""}),
                    id: "{id}",
                    aria_label: "{aria_label}",
                    width: "100%",
                    contenteditable: true,
                    dangerous_inner_html: format_args!("{}", syntax_highlight(&text_value.read())),
                    //disabled: "{disabled}",
                    //value: "{text_value.read()}",
                    //maxlength: "{max_length}",
                    //placeholder: format_args!("{}", if *is_disabled {""} else {placeholder}),
                    onblur: move |_| {
                        onreturn.call((text_value.read().to_string(), false, Code::Enter));
                    },
                    oninput: {
                        to_owned![eval, cursor_script];
                        move |evt| {
                            let current_val = evt.value.clone();
                            *text_value.write_silent() = current_val.clone();
                            onchange.call((current_val, true));
                            to_owned![eval, cursor_script, cursor_position];
                            async move {
                                if do_cursor_update {
                                    if let Ok(r) = eval(&cursor_script) {
                                        if let Ok(val) = r.join().await {
                                            *cursor_position.write() = Some(val.as_i64().unwrap_or_default());
                                        }
                                    }
                                }
                            }
                        }
                    },
                    onkeyup: move |evt| {
                        match evt.code() {
                            Code::ShiftLeft => *left_shift_pressed.write_silent() = false,
                            Code::ShiftRight => *right_shift_pressed.write_silent() = false,
                            Code::Enter => *enter_pressed.write_silent() = false,
                            Code::NumpadEnter => *numpad_enter_pressed.write_silent() = false,
                            _ => {}
                        };
                    },
                    onmousedown: {
                        to_owned![eval, cursor_script];
                        move |_| {
                            to_owned![eval, cursor_script, cursor_position];
                            async move {
                                if do_cursor_update {
                                    if let Ok(r) = eval(&cursor_script) {
                                        if let Ok(val) = r.join().await {
                                            *cursor_position.write() = Some(val.as_i64().unwrap_or_default());
                                        }
                                    }
                                }
                            }
                        }
                    },
                    onkeydown: {
                        to_owned![eval, cursor_script];
                        move |evt| {
                            // special codepath to handle onreturn
                            let old_enter_pressed = *enter_pressed.read();
                            let old_numpad_enter_pressed = *numpad_enter_pressed.read();
                            match evt.code() {
                                Code::ShiftLeft => if !*left_shift_pressed.read() { *left_shift_pressed.write_silent() = true; },
                                Code::ShiftRight => if !*right_shift_pressed.read() { *right_shift_pressed.write_silent() = true; },
                                Code::Enter => if !*enter_pressed.read() { *enter_pressed.write_silent() = true; } ,
                                Code::NumpadEnter => if !*numpad_enter_pressed.read() { *numpad_enter_pressed.write_silent() = true; },
                                _ => {}
                            };
                            // write_silent() doesn't update immediately. if the enter key is pressed, have to check the evt code
                            let enter_toggled = !old_enter_pressed && matches!(evt.code(), Code::Enter);
                            let numpad_enter_toggled = !old_numpad_enter_pressed && matches!(evt.code(), Code::NumpadEnter);
                            if (enter_toggled || numpad_enter_toggled) && !(*right_shift_pressed.read() || *left_shift_pressed.read())
                            {
                                 if *show_char_counter {
                                        let _ = eval(&clear_counter_script);
                                    }
                                    onreturn.call((text_value.read().clone(), true, evt.code()));
                            }

                            // special codepath to handle the arrow keys
                            let arrow = match evt.code() {
                                Code::ArrowDown|Code::ArrowUp => {
                                    if let Some(e) = onup_down_arrow {
                                        e.call(evt.code());
                                    };
                                    true
                                }
                                Code::ArrowLeft|Code::ArrowRight => {
                                    true
                                }
                                _ => {
                                    false
                                }
                            };
                            to_owned![eval, cursor_script, cursor_position];
                            async move {
                                if do_cursor_update && arrow {
                                    if let Ok(r) = eval(&cursor_script) {
                                        if let Ok(val) = r.join().await {
                                            *cursor_position.write() = Some(val.as_i64().unwrap_or_default());
                                        }
                                    }
                                }
                            }
                        }
                    },
                },
                if *show_char_counter {
                    rsx!(
                        div {
                            class: "input-char-counter",
                            p {
                                key: "{id_char_counter}-char-counter",
                                id: "{id_char_counter}-char-counter",
                                aria_label: "input-char-counter",
                                class: "char-counter-p-element",
                                format!("{}", text_value.read().len()),
                            },
                            p {
                                key: "{id_char_counter}-char-max-length",
                                id: "{id_char_counter}-char-max-length",
                                class: "char-counter-p-element",
                                format!("/{}", max_length - 1),
                            }
                        }
                        )
                }
            },
        }
        script { script },
        script { focus_script }
    ))
}
