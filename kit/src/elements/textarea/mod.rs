//! This was made for the chatbar but it turns out that a contenteditable div is needed to render markdown. This is a temporary solution.
//! this could be merged with kit/src/elements/input and make the input element use a textarea based on a property.
//! that might helpful if a textarea needed to perform input validation.

use dioxus::prelude::*;
use dioxus_html::input_data::keyboard_types::{Code, Modifiers};

use crate::elements::tooltip::{ArrowPosition, Tooltip};

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
    #[props(default = false)]
    loading: bool,
    #[props(default = "".to_owned())]
    placeholder: String,
    #[props(default = 1024)]
    max_length: i32,
    #[props(default = Size::Normal)]
    size: Size,
    #[props(default = "".to_owned())]
    default_text: String,
    #[props(default = "".to_owned())]
    aria_label: String,
    onchange: EventHandler<'a, (String, bool)>,
    onreturn: EventHandler<'a, (String, bool, Code)>,
    #[props(!optional)]
    reset: Option<UseState<bool>>,
    #[props(optional)]
    is_disabled: Option<bool>,
    #[props(optional)]
    tooltip: Option<String>,
}

#[allow(non_snake_case)]
pub fn Input<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let val = use_ref(cx, || cx.props.default_text.clone());

    if let Some(hook) = &cx.props.reset {
        let should_reset = hook.get();
        if *should_reset {
            val.write().clear();
            hook.set(false);
        }
    }

    let element_id = &cx.props.id;
    let element_label = &cx.props.aria_label;
    let element_max_length = cx.props.max_length;
    let element_placeholder = &cx.props.placeholder;
    let disabled = cx.props.loading || cx.props.is_disabled.unwrap_or_default();

    let eval = dioxus_desktop::use_eval(cx);
    // only run this after the component has been mounted and when the id of the input changes
    use_effect(cx, (&cx.props.id,), move |(id,)| {
        to_owned![eval];
        async move {
            let script = include_str!("./script.js")
                .replace("$UUID", &id)
                .replace("$MULTI_LINE", "true");
            eval(script);
            let focus_script = include_str!("./focus.js").replace("UUID", &id);
            eval(focus_script);
        }
    });

    //This should run everytime the component is updated
    let height_script = include_str!("./update_input_height.js");
    eval(height_script.to_string());

    cx.render(rsx! (
        div {
            class: "input-group",
            div {
                class: format_args!("input {}", if disabled { "disabled" } else { " " }),
                height: cx.props.size.get_height(),
                textarea {
                    key: "{element_id}",
                    class: "input_textarea",
                    id: "{element_id}",
                    // todo: troubleshoot this. it isn't working
                    // edit: autofocus does not work for input elements
                    // see https://github.com/DioxusLabs/dioxus/issues/725
                    autofocus: cx.props.focus,
                    aria_label: "{element_label}",
                    disabled: "{disabled}",
                    value: "{val.read()}",
                    maxlength: "{element_max_length}",
                    placeholder: format_args!("{}", if cx.props.is_disabled.unwrap_or_default() {""} else {element_placeholder}),
                    oninput: move |evt| {
                        let current_val = evt.value.clone();
                        *val.write_silent() = current_val;
                        if !val.read().trim().is_empty() {
                            cx.props.onchange.call((val.read().to_string(), true));
                        }
                    },
                    onkeyup: move |evt| {
                        let is_valid = !val.read().trim().is_empty();
                        if evt.code() == Code::Enter && !evt.data.modifiers().contains(Modifiers::SHIFT) {
                            cx.props.onreturn.call((val.read().to_string(), is_valid, evt.code()));
                        }
                    }
                }
            },
            cx.props.tooltip.as_deref().filter(|s| cx.props.is_disabled.unwrap_or_default() && !s.is_empty()).map(|s| cx.render(rsx!(
                Tooltip {
                    arrow_position: ArrowPosition::None,
                    text: s.to_string(),
                }
            )))
        }
    ))
}
