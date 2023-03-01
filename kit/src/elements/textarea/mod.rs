use dioxus::prelude::*;
use dioxus_html::input_data::keyboard_types::{Code, Modifiers};

pub type ValidationError = String;
use crate::elements::label::Label;

use common::icons::outline::Shape as Icon;
use common::icons::Icon as IconElement;

#[derive(PartialEq, Clone)]
pub enum SpecialCharsAction {
    Allow,
    Block,
}

#[derive(Default, Clone)]
pub struct Options {
    pub disabled: bool,
    pub with_clear_btn: bool,
    pub with_label: Option<&'static str>,
    pub react_to_esc_key: bool,
}

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
    focus: bool,
    _loading: Option<bool>,
    placeholder: String,
    #[props(default = Size::Normal)]
    size: Size,
    default_text: Option<String>,
    aria_label: Option<String>,
    allow_line_breaks: Option<bool>,
    disabled: Option<bool>,
    icon: Option<Icon>,
    options: Option<Options>,
    onchange: Option<EventHandler<'a, (String, bool)>>,
    onreturn: Option<EventHandler<'a, (String, bool, Code)>>,
    reset: Option<UseState<bool>>,
}

fn emit(cx: &Scope<Props>, s: String, is_valid: bool) {
    if let Some(f) = &cx.props.onchange {
        f.call((s, is_valid));
    }
}

fn emit_return(cx: &Scope<Props>, s: String, is_valid: bool, key_code: Code) {
    if let Some(f) = &cx.props.onreturn {
        f.call((s, is_valid, key_code));
    }
}

fn get_icon(cx: &Scope<Props>) -> Icon {
    cx.props.icon.unwrap_or(Icon::QuestionMarkCircle)
}

fn get_text(cx: &Scope<Props>) -> String {
    cx.props.default_text.clone().unwrap_or_default()
}

fn get_aria_label(cx: &Scope<Props>) -> String {
    cx.props.aria_label.clone().unwrap_or_default()
}

fn get_label(cx: &Scope<Props>) -> String {
    let options = cx.props.options.clone().unwrap_or_default();
    options
        .with_label
        .map(|text| text.to_string())
        .unwrap_or_default()
}

#[allow(non_snake_case)]
pub fn Input<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let error = use_state(cx, || String::from(""));
    let val = use_ref(cx, || get_text(&cx));
    let options = cx.props.options.clone().unwrap_or_default();

    if let Some(hook) = &cx.props.reset {
        let should_reset = hook.get();
        if *should_reset {
            val.write().clear();
            hook.set(false);
        }
    }
    let height_script = include_str!("./update_input_height.js");
    dioxus_desktop::use_eval(cx)(height_script.to_string());

    // todo: how large can this be? 1kb seems like plenty
    let max_length = 1024;
    let aria_label = get_aria_label(&cx);
    let label = get_label(&cx);
    let disabled = cx.props.disabled.unwrap_or_default();
    let multiline = cx.props.allow_line_breaks.unwrap_or_default();

    let input_id = cx.props.id.clone();
    let script = include_str!("./script.js")
        .replace("UUID", &cx.props.id)
        .replace("$APPLY_FOCUS", &format!("{}", &cx.props.focus))
        .replace("$MULTI_LINE", &format!("{}", &multiline));

    cx.render(rsx! (
        div {
            class: {
                format_args!("input-group {}", if disabled { "disabled" } else { " "})
            },
            (!label.is_empty()).then(|| rsx! (
                Label {
                    text: label
                }
            ))
            div {
                class: "input",
                height: cx.props.size.get_height(),
                // If an icon was provided, render it before the input.
                (cx.props.icon.is_some()).then(|| rsx!(
                    span {
                        class: "icon",
                        IconElement {
                            icon: get_icon(&cx)
                        }
                    }
                )),
                script { "{script}"},
                textarea {
                    class: "input_textarea",
                    id: "{input_id}",
                    aria_label: "{aria_label}",
                    disabled: "{disabled}",
                    value: format_args!("{}", val.read()),
                    maxlength: "{max_length}",
                    placeholder: "{cx.props.placeholder}",
                    oninput: move |evt| {
                        let current_val = evt.value.clone();
                        *val.write_silent() = current_val;
                        if !val.read().trim().is_empty() {
                            emit(&cx, val.read().to_string(), true);
                        }
                    },
                    onkeyup: move |evt| {
                        let is_valid = !val.read().trim().is_empty();
                        if evt.code() == Code::Enter {
                            if !multiline || !evt.data.modifiers().contains(Modifiers::SHIFT) {
                                emit_return(&cx, val.read().to_string(), is_valid, evt.code());
                            }
                        } else if options.react_to_esc_key && evt.code() == Code::Escape {
                            emit_return(&cx, "".to_owned(), is_valid, evt.code());
                        }
                    }
                }
                (options.with_clear_btn && !val.read().is_empty()).then(|| rsx!(
                    div {
                        class: "clear-btn",
                        onclick: move |_| {
                            *val.write() = "".into();
                            emit(&cx, val.read().to_string(), false);
                            error.set("".into());
                        },
                        IconElement {
                            icon: Icon::Backspace
                        }
                    }
                )),
            },
            (!error.is_empty()).then(|| rsx!(
                p {
                    class: "error",
                    aria_label: "input-error",
                    "{error}"
                }
            ))
        }
    ))
}
