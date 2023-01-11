use dioxus::{prelude::*};
use dioxus_html::input_data::keyboard_types::Code;
use shared::language::get_local_text;

pub type ValidationError = String;
use crate::{icons::{Icon, IconElement}, elements::label::Label};


#[derive(Default, Clone, Copy)]
pub struct Validation {
    pub max_length: Option<i32>,
    pub min_length: Option<i32>,
    pub alpha_numeric_only: bool,
    pub no_whitespace: bool,
}

#[derive(Default, Clone, Copy)]
pub struct Options {
    pub with_validation: Option<Validation>,
    pub replace_spaces_underscore: bool, 
    pub disabled: bool,
    pub with_clear_btn: bool,
    pub with_label: Option<&'static str>,
}

#[derive(Props)]
pub struct Props<'a> {
    #[props(default = "".to_owned())]
    id: String,
    #[props(default = false)]
    focus: bool,
    #[props(optional)]
    _loading: Option<bool>,
    placeholder: String,
    #[props(optional)]
    max_length: Option<i32>,
    #[props(optional)]
    default_text: Option<String>,
    #[props(optional)]
    aria_label: Option<String>,
    #[props(optional)]
    is_password: Option<bool>,
    #[props(optional)]
    disabled: Option<bool>,
    #[props(optional)]
    icon: Option<Icon>,
    #[props(optional)]
    options: Option<Options>,
    #[props(optional)]
    onchange: Option<EventHandler<'a, (String, bool)>>,
    #[props(optional)]
    onreturn: Option<EventHandler<'a, (String, bool)>>,
}

pub fn emit(cx: &Scope<Props>, s: String, is_valid: bool) {
    if let Some(f) =  &cx.props.onchange {
       f.call((s, is_valid));
    }
}

pub fn emit_return(cx: &Scope<Props>, s: String, is_valid: bool) {
    if let Some(f) =  &cx.props.onreturn {
        f.call((s, is_valid));
    }
}

// warning: this function wasn't used so I'm assuming it will only be called if the input is validated.
pub fn submit(cx: &Scope<Props>, s: String) {
    if let Some(f) =  &cx.props.onreturn {
      f.call((s, true));
    }
}

pub fn validate_no_whitespace(val: &str) -> Option<ValidationError> {
    if val.contains(char::is_whitespace) {
        return Some(get_local_text("warning-messages.spaces-not-allowed"));
    }
    None
}

pub fn validate_alphanumeric(val: &str) -> Option<ValidationError> {
    if val.chars().all(char::is_alphanumeric) {
        return Some(get_local_text("warning-messages.only-alpha-chars"));
    }
    None
}

pub fn validate_min_max(val: &str, min: Option<i32>, max: Option<i32>) -> Option<ValidationError> {
    let max = max.unwrap_or_default() as usize;
    let min = min.unwrap_or_default() as usize;

    // Ensure the maximum value isn't the default
    // then make sure the value's length is less than or equal to the max
    if max > 0 && val.len() > max {
        return Some(format!("{} {} {} {}.", get_local_text("warning-messages.maximum-of"),
         max, get_local_text("uplink.characters"), get_local_text("uplink.exceeded")));
    }

    // Ensure the minimum is not the default value
    // then make sure the value's length is greater than or equal to the minimum
    if min > 0 && val.len() < min {
        return Some(format!("{} {} {}.",  get_local_text("warning-messages.please-enter-at-least"), min, get_local_text("uplink.characters")));
    }

    None
}

pub fn get_icon(cx: &Scope<Props>) -> Icon {
    cx.props.icon.unwrap_or(Icon::QuestionMarkCircle)
}

pub fn get_text(cx: &Scope<Props>) -> String {
    cx.props.default_text.clone().unwrap_or_default()
}

pub fn get_aria_label(cx: &Scope<Props>) -> String {
    cx.props.aria_label.clone().unwrap_or_default()
}

pub fn get_label(cx: &Scope<Props>) -> String {
    let options =  cx.props.options.unwrap_or_default();
    options.with_label.map(|text| text.to_string()).unwrap_or_default()
}

pub fn validate(cx: &Scope<Props>, val: &str) -> Option<ValidationError> {
    let mut error: Option<ValidationError> = None;

    let options = cx.props.options.unwrap_or_default();

    let validation = options.with_validation.unwrap_or_default();

    if validation.alpha_numeric_only {
        error = validate_alphanumeric(val);
    }

    if validation.no_whitespace {
        error = validate_no_whitespace(val);
    }

    if validation.max_length.is_some() || validation.min_length.is_some() {
        error = validate_min_max(val, validation.min_length, validation.max_length);
    }

    error
}

#[allow(non_snake_case)]
pub fn Input<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let error = use_state(cx, || String::from(""));
    let val = use_ref(cx, || get_text(&cx));
    let max_length = cx.props.max_length.unwrap_or(std::i32::MAX);
    let options = cx.props.options.unwrap_or_default();

    let valid = use_state(cx, || false);
    let min_len =  options.with_validation.map(|opt| opt.min_length.unwrap_or_default()).unwrap_or_default();
    let apply_validation_class = options.with_validation.is_some();
    let aria_label = get_aria_label(&cx);
    let label = get_label(&cx);

    let disabled = cx.props.disabled.unwrap_or_default();

    let typ = cx.props.is_password.and_then(|b| b.then_some("password")).unwrap_or("text");

    let input_id = cx.props.id.clone();
    let script = include_str!("./script.js").replace("UUID", &cx.props.id);

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
                class: {
                    format_args!("input {}", if *valid.current() && apply_validation_class { "input-success" } else if !error.is_empty() && apply_validation_class { "input-warning" } else { "" })
                },
                // If an icon was provided, render it before the input.
                (cx.props.icon.is_some()).then(|| rsx!(
                    span {
                        class: "icon",
                        IconElement { 
                            icon: get_icon(&cx)
                        }
                    }
                )),
                cx.props.focus.then(|| rsx!(
                    script { "{script}"},
                )),
                input {
                    id: "{input_id}",
                    aria_label: "{aria_label}",
                    disabled: "{disabled}",
                    value: format_args!("{}", val.read()),
                    maxlength: "{max_length}",
                    "type": "{typ}",
                    placeholder: "{cx.props.placeholder}",
                    oninput: move |evt| {
                        let current_val = evt.value.clone();
                        let validation_result = validate(&cx, &current_val).unwrap_or_default();
                        error.set(validation_result.clone());
                        *val.write_silent() = current_val.to_string();

                        if !validation_result.is_empty() {
                            valid.set(false);
                            evt.stop_propagation();
                        } else if current_val.len() >= min_len as usize {
                            valid.set(true);
                        }
                        emit(&cx, val.read().to_string(), *valid.current());
                    },
                    onkeyup: move |evt| {
                        if evt.code() == Code::Enter {
                            emit_return(&cx, val.read().to_string(), *valid.current());
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
                            valid.set(false);
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
