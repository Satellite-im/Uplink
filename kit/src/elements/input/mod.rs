use common::language::get_local_text;
use dioxus::prelude::*;
use dioxus_desktop::use_eval;
use dioxus_html::input_data::keyboard_types::Code;
use uuid::Uuid;

pub type ValidationError = String;
use crate::elements::label::Label;

use common::icons::outline::Shape as Icon;
use common::icons::Icon as IconElement;

use super::label::LabelWithEllipsis;

/// This vector of special chars must be used to decide which char can or cannot be allowed in the input field.
/// Just use this if quantity of chars you want to block and allow are similar.
/// If not, is best to use SpecialCharsAction to pass small vecs.
///
/// ## Example:
/// ```rust
/// let chars_to_remove = vec!['\\', '/', ';', ':', '\'', '\"', ',', '<', '>', '.', '/', '?', '~', '_'];
/// let mut special_chars = SPECIAL_CHARS.to_vec();
/// special_chars = special_chars
///    .iter()
///    .filter(|&&c| !chars_to_remove.contains(&c))
///    .cloned()
///    .collect();
/// rsx! (
/// Input {
///  ...
/// options: Options {
///    with_validation: Some(Validation {
///        alpha_numeric_only: true,
///        special_chars_allowed: Some(special_chars),
///        ..Validation::default()
///    }),
///    ..Options::default()
/// }
/// ...
/// )
/// ```
pub static SPECIAL_CHARS: &[char] = &[
    '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '-', '+', '=', '{', '}', '[', ']', '|', '\\',
    ';', ':', '\'', '\"', ',', '<', '>', '.', '/', '?', '~', '_',
];

#[derive(PartialEq, Clone)]
pub enum SpecialCharsAction {
    Allow,
    Block,
}

#[derive(Default, Clone)]
pub struct Validation {
    pub max_length: Option<i32>,
    pub min_length: Option<i32>,
    pub alpha_numeric_only: bool,
    pub ignore_colons: bool,
    pub no_whitespace: bool,
    /// Decide if allow or block some chars, to keeping block any special char
    /// just pass None as value
    ///
    /// ### Example
    ///
    /// ```rust
    ///  options: Options {
    ///        react_to_esc_key: true,
    ///     with_validation: Some(Validation {
    ///             alpha_numeric_only: true,
    ///             special_chars: Some((SpecialCharsAction::Block, vec!['\\', '/'])),
    ///             ..Validation::default()
    ///         }),
    ///         ..Options::default()
    ///     }
    /// ```
    pub special_chars: Option<(SpecialCharsAction, Vec<char>)>,
}

#[derive(Clone)]
pub struct Options {
    pub with_validation: Option<Validation>,
    pub replace_spaces_underscore: bool,
    pub disabled: bool,
    pub with_clear_btn: bool,
    pub clear_btn_icon: Icon,
    pub clear_on_submit: bool,
    pub with_label: Option<String>,
    pub ellipsis_on_label: Option<LabelWithEllipsis>,
    pub react_to_esc_key: bool,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            with_validation: None,
            replace_spaces_underscore: false,
            disabled: false,
            with_clear_btn: false,
            clear_btn_icon: Icon::Backspace,
            clear_on_submit: true,
            with_label: None,
            ellipsis_on_label: None,
            react_to_esc_key: false,
        }
    }
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
    loading: Option<bool>,
    placeholder: String,
    max_length: Option<i32>,
    #[props(default = Size::Normal)]
    size: Size,
    default_text: Option<String>,
    aria_label: Option<String>,
    is_password: Option<bool>,
    disabled: Option<bool>,
    #[props(optional)]
    icon: Option<Icon>,
    #[props(optional)]
    value: Option<String>,
    options: Option<Options>,
    onchange: Option<EventHandler<'a, (String, bool)>>,
    onreturn: Option<EventHandler<'a, (String, bool, Code)>>,
    reset: Option<UseState<bool>>,
    #[props(default = false)]
    disable_onblur: bool,
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

// warning: this function wasn't used so I'm assuming it will only be called if the input is validated.
#[allow(unused)]
fn submit(cx: &Scope<Props>, s: String) {
    if let Some(f) = &cx.props.onreturn {
        f.call((s, true, Code::Enter));
    }
}

fn validate_no_whitespace(val: &str) -> Option<ValidationError> {
    if val.contains(char::is_whitespace) {
        return Some(get_local_text("warning-messages.spaces-not-allowed"));
    }
    None
}

// Default to requiring alpha-numeric inputs, unless ignore_colon override is set on the input field
fn validate_alphanumeric(
    val: &str,
    ignore_colon: bool,
    special_characters: Option<(SpecialCharsAction, Vec<char>)>,
) -> Option<ValidationError> {
    let mut val = val.to_string();
    if ignore_colon {
        val.retain(|c| c != ':');
    }

    if let Some((action, chars)) = special_characters {
        let mut special_chars_allowed = SPECIAL_CHARS.to_vec();
        if action == SpecialCharsAction::Block {
            special_chars_allowed = special_chars_allowed
                .iter()
                .filter(|&&c| !chars.contains(&c))
                .cloned()
                .collect();
        } else {
            special_chars_allowed = chars;
        }
        for s in special_chars_allowed {
            val.retain(|c| c != s);
        }
    }

    if !val.chars().all(char::is_alphanumeric) {
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
        return Some(format!(
            "{} {} {} {}.",
            get_local_text("warning-messages.maximum-of"),
            max,
            get_local_text("uplink.characters"),
            get_local_text("uplink.exceeded")
        ));
    }

    // Ensure the minimum is not the default value
    // then make sure the value's length is greater than or equal to the minimum
    if min > 0 && val.len() < min {
        return Some(format!(
            "{} {} {}.",
            get_local_text("warning-messages.please-enter-at-least"),
            min,
            get_local_text("uplink.characters")
        ));
    }

    None
}

pub fn get_icon(cx: &Scope<Props>) -> Icon {
    cx.props.icon.unwrap_or(Icon::QuestionMarkCircle)
}

pub fn get_aria_label(cx: &Scope<Props>) -> String {
    cx.props.aria_label.clone().unwrap_or_default()
}

pub fn get_label(cx: &Scope<Props>) -> String {
    let options = cx.props.options.clone().unwrap_or_default();
    options.with_label.unwrap_or_default()
}

pub fn validate(cx: &Scope<Props>, val: &str) -> Option<ValidationError> {
    let mut error: Option<ValidationError> = None;

    let options = cx.props.options.clone().unwrap_or_default();

    let validation = options.with_validation.unwrap_or_default();

    if validation.alpha_numeric_only
        && validate_alphanumeric(
            val,
            validation.ignore_colons,
            validation.special_chars.clone(),
        )
        .is_some()
    {
        error = validate_alphanumeric(val, validation.ignore_colons, validation.special_chars);
    }

    if validation.no_whitespace && validate_no_whitespace(val).is_some() {
        error = validate_no_whitespace(val);
    }

    if (validation.max_length.is_some() || validation.min_length.is_some())
        && validate_min_max(val, validation.min_length, validation.max_length).is_some()
    {
        error = validate_min_max(val, validation.min_length, validation.max_length);
    }

    error
}

#[allow(non_snake_case)]
pub fn Input<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    // Input element needs an id. Create a new one if an id wasn't specified
    let input_id = use_state(cx, || {
        if cx.props.id.is_empty() {
            Uuid::new_v4().to_string()
        } else {
            cx.props.id.clone()
        }
    });
    let error = use_state(cx, || String::from(""));
    let val = use_ref(cx, || cx.props.default_text.clone().unwrap_or_default());
    let max_length = cx.props.max_length.unwrap_or(std::i32::MAX);
    let min_length = cx.props.max_length.unwrap_or(0);
    let options = cx.props.options.clone().unwrap_or_default();
    let should_validate = options.with_validation.is_some();
    let valid = use_state(cx, || false);
    let onblur_active = !cx.props.disable_onblur;

    let loading_class = match cx.props.loading.unwrap_or(false) {
        true => "progress",
        false => "",
    };

    if let Some(value) = &cx.props.value {
        val.set(value.clone());
    }

    let reset_fn = || {
        *val.write() = "".into();
        error.set("".into());
        valid.set(false);
    };
    if let Some(hook) = &cx.props.reset {
        let should_reset = hook.get();
        if *should_reset {
            reset_fn();
            hook.set(false);
        }
    }

    let apply_validation_class = should_validate;
    let aria_label = get_aria_label(&cx);
    let label = get_label(&cx);

    let disabled = cx.props.disabled.unwrap_or_default() || cx.props.loading.unwrap_or(false);

    let typ = cx
        .props
        .is_password
        .and_then(|b| b.then_some("password"))
        .unwrap_or("text");

    // Run the script after the component is mounted.
    let eval = use_eval(cx);
    use_effect(cx, (&cx.props.focus, input_id), move |(focus, input_id)| {
        to_owned![eval];
        async move {
            if focus {
                let script = include_str!("./script.js").replace("UUID", &input_id);
                eval(script);
            }
        }
    });

    cx.render(rsx! (
        div {
            class: {
                format_args!("input-group {}", if disabled { "disabled" } else { " "})
            },
            (!label.is_empty()).then(|| rsx! (
                Label {
                    text: label,
                    label_with_ellipsis: options.ellipsis_on_label.unwrap_or_default(),
                }
            ))
            div {
                class: {
                    format_args!("input {}", if *valid.current() && apply_validation_class { "input-success" } else if !error.is_empty() && apply_validation_class { "input-warning" } else { "" })
                },
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
                input {
                    id: "{input_id}",
                    class: "{loading_class}",
                    aria_label: "{aria_label}",
                    disabled: "{disabled}",
                    value: "{val.read()}",
                    maxlength: "{max_length}",
                    "type": "{typ}",
                    placeholder: "{cx.props.placeholder}",
                    onblur: move |_| {
                        if onblur_active {
                            emit_return(&cx, val.read().to_string(), *valid.current(), Code::Enter);
                            valid.set(false);
                            if options.clear_on_submit {
                                reset_fn();
                            }
                        }
                    },
                    oninput: move |evt| {
                        let current_val = evt.value.clone();
                        *val.write_silent() = current_val.clone();

                        let is_valid = if should_validate {
                            let validation_result = validate(&cx, &current_val).unwrap_or_default();
                            valid.set(validation_result.is_empty());
                            error.set(validation_result);
                            evt.stop_propagation();
                            *valid.current()
                        } else {
                            true
                        };
                        emit(&cx, current_val, is_valid);
                    },
                    // after a valid submission, don't keep the input box green. 
                    onkeyup: move |evt| {
                        if evt.code() == Code::Enter || evt.code() == Code::NumpadEnter {
                            emit_return(&cx, val.read().to_string(), *valid.current(), evt.code());
                            if *valid.current() {
                                 valid.set(false);
                            }
                            if options.clear_on_submit {
                                reset_fn();
                            }
                        } else if options.react_to_esc_key && evt.code() == Code::Escape {
                            emit_return(&cx, "".to_owned(), min_length == 0, evt.code());
                            if *valid.current() {
                                valid.set(false);
                           }
                            if options.clear_on_submit {
                                reset_fn();
                           }
                        }
                    }
                },
                (options.with_clear_btn && !val.read().is_empty() && !disabled).then(move || rsx!(
                    div {
                        class: "clear-btn",
                        onclick: move |_| {
                            *val.write_silent() = String::new();
                            if should_validate {
                                let validation_result = validate(&cx, "").unwrap_or_default();
                                valid.set(validation_result.is_empty());
                                error.set(validation_result);
                            }
                            // re-focus the input after clearing it
                            let script = include_str!("./script.js").replace("UUID", input_id);
                            dioxus_desktop::use_eval(cx)(script);
                        },
                        IconElement {
                            icon: options.clear_btn_icon
                        }
                    }
                )),
                cx.props.loading.unwrap_or(false).then(move || rsx!(
                    IconElement {
                        icon: Icon::Loader
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
