use dioxus::{prelude::*, events::KeyCode};

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
    #[props(optional)]
    _loading: Option<bool>,
    placeholder: String,
    #[props(optional)]
    default_text: Option<String>,
    #[props(optional)]
    is_password: Option<bool>,
    #[props(optional)]
    disabled: Option<bool>,
    #[props(optional)]
    icon: Option<Icon>,
    #[props(optional)]
    options: Option<Options>,
    #[props(optional)]
    onchange: Option<EventHandler<'a, String>>,
    #[props(optional)]
    onreturn: Option<EventHandler<'a, String>>,
}

pub fn emit(cx: &Scope<Props>, s: String) {
    match &cx.props.onchange {
        Some(f) => f.call(s),
        None    => {},
    }
}

pub fn emit_return(cx: &Scope<Props>, s: String) {
    match &cx.props.onreturn {
        Some(f) => f.call(s),
        None    => {},
    }
}

pub fn submit(cx: &Scope<Props>, s: String) {
    match &cx.props.onreturn {
        Some(f) => f.call(s),
        None    => {},
    }
}

pub fn validate_no_whitespace(val: &str) -> Option<ValidationError> {
    if val.contains(char::is_whitespace) {
        return Some("Spaces are not allowed.".into());
    }
    None
}

pub fn validate_alphanumeric(val: &str) -> Option<ValidationError> {
    if val.chars().all(char::is_alphanumeric) {
        return Some("Only alphanumeric characters are accepted.".into());
    }
    None
}

pub fn validate_min_max(val: &str, min: Option<i32>, max: Option<i32>) -> Option<ValidationError> {
    let max = max.unwrap_or_default() as usize;
    let min = min.unwrap_or_default() as usize;

    // Ensure the maximum value isn't the default
    // then make sure the value's length is less than or equal to the max
    if max > 0 && val.len() > max {
        return Some(format!("Maximum of {} characters exceeded.", max));
    }

    // Ensure the minimum is not the default value
    // then make sure the value's length is greater than or equal to the minimum
    if min > 0 && val.len() < min {
        return Some(format!("Please enter at least {} characters.", min));
    }

    None
}

pub fn get_icon(cx: &Scope<Props>) -> Icon {
    match &cx.props.icon {
        Some(icon) => icon.to_owned(),
        None => Icon::QuestionMarkCircle,
    }
}

pub fn get_text(cx: &Scope<Props>) -> String {
    let default_text = String::from("");
    match &cx.props.default_text {
        Some(text) => text.clone(),
        None => default_text,
    }
}

pub fn get_label(cx: &Scope<Props>) -> String {
    let default_options = Options::default();

    let options = match cx.props.options {
        Some(opts) => opts,
        None => default_options,
    };
    let default_text = "";
    match options.with_label {
        Some(text) => text.to_string(),
        None => default_text.to_string(),
    }
}
pub fn validate(cx: &Scope<Props>, val: &str) -> Option<ValidationError> {
    let default_validation = Validation::default();
    let default_options = Options::default();

    let mut error: Option<ValidationError> = None;

    let options = match cx.props.options {
        Some(opts) => opts,
        None => default_options,
    };

    let validation = match &options.with_validation {
        Some(v) => v,
        None => &default_validation,
    };

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
    let error = use_state(&cx, || String::from(""));
    let val = use_state(&cx, || get_text(&cx));
    let default_options = Options::default();
    let options = match &cx.props.options {
        Some(opts) => opts,
        None => &default_options,
    };
    let valid = use_state(&cx, || false);
    let min_len = match options.with_validation {
        Some(opts) => opts.min_length.unwrap_or_default(),
        None => 0,
    };
    let apply_validation_class = options.with_validation.is_some();
    let label = get_label(&cx);

    let disabled = &cx.props.disabled.unwrap_or_default();

    let typ = match cx.props.is_password {
        Some(b) => if b { "password" } else { "text" },
        None => "text",
    };

    cx.render(rsx! (
        div {
            class: {
                format_args!("input-group {}", if *disabled { "disabled" } else { " "})
            },
            (!label.is_empty()).then(|| rsx! (
                Label {
                    text: label
                }
            ))
            div {
                class: {
                    format_args!("input {}", if **valid && apply_validation_class { "input-success" } else if !error.is_empty() && apply_validation_class { "input-warning" } else { "" })
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
                input {
                    disabled: "{disabled}",
                    value: "{val}",
                    "type": "{typ}",
                    placeholder: "{cx.props.placeholder}",
                    oninput: move |evt| {
                        let current_val = evt.value.clone();
                        let validation_result = validate(&cx, &current_val).unwrap_or_default();
                        error.set(validation_result.clone());
                        val.set(current_val.clone());
                        if !validation_result.is_empty() {
                            valid.set(false);
                            evt.cancel_bubble();
                        } else if current_val.len() >= min_len as usize {
                            valid.set(true);
                        }
                        emit(&cx, val.to_string());
                    },
                    onkeyup: move |evt| {
                        if evt.key_code == KeyCode::Enter {
                            emit_return(&cx, val.to_string());
                        }
                    }
                }
                (options.with_clear_btn && !val.is_empty()).then(|| rsx!(
                    div {
                        class: "clear-btn",
                        onclick: move |_| {
                            val.set("".into());
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
                    "{error}"
                }
            ))
        }
    ))
}
