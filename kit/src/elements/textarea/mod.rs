//! This was made for the chatbar but it turns out that a contenteditable div is needed to render markdown. This is a temporary solution.
//! this could be merged with kit/src/elements/input and make the input element use a textarea based on a property.
//! that might helpful if a textarea needed to perform input validation.

use std::{cell::RefCell, rc::Rc};

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
    aria_label: String,
    onchange: EventHandler<'a, (String, bool)>,
    onreturn: EventHandler<'a, (String, bool, Code)>,
    value: String,
    #[props(default = false)]
    is_disabled: bool,
    #[props(default = "".to_owned())]
    tooltip: String,
}

#[allow(non_snake_case)]
pub fn Input<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let Props {
        id,
        focus,
        loading,
        placeholder,
        max_length,
        size,
        aria_label,
        onchange,
        onreturn,
        value,
        is_disabled,
        tooltip,
    } = &cx.props;

    let height_script = include_str!("./update_input_height.js");
    let focus_script = include_str!("./focus.js").replace("UUID", id);
    dioxus_desktop::use_eval(cx)(height_script.to_string());
    dioxus_desktop::use_eval(cx)(focus_script.to_string());

    let script = include_str!("./script.js")
        .replace("$UUID", id)
        .replace("$MULTI_LINE", &format!("{}", true));
    let current_val = value.to_string();
    let disabled = *loading || *is_disabled;

    let cv2 = current_val.clone();

    let text_value = Rc::new(RefCell::new(value.to_string()));
    let text_value_onchange = Rc::clone(&text_value);
    let text_value_onkeyup = Rc::clone(&text_value);
    let text_value_onreturn = Rc::clone(&text_value);

    cx.render(rsx! (
        div {
            class: "input-group",
            aria_label: "input-group",
            div {
                class: format_args!("input {}", if disabled { "disabled" } else { " " }),
                height: "{size.get_height()}",
                script { "{script}" },
                textarea {
                    key: "{element_id}",
                    class: "input_textarea",
                    id: "{id}",
                    // todo: troubleshoot this. it isn't working
                    autofocus: *focus,
                    aria_label: "{aria_label}",
                    disabled: "{disabled}",
                    value: "{current_val}",
                    maxlength: "{max_length}",
                    placeholder: format_args!("{}", if *is_disabled {""} else {placeholder}),
                    onblur: move |_| {
                        onreturn.call((cv2.to_string(), false, Code::Enter));
                    },
                    oninput: move |evt| {
                        let current_val = evt.value.clone();
                        text_value_onchange.borrow_mut().clear();
                        text_value_onchange.borrow_mut().push_str(&current_val);
                        onchange.call((current_val, true));
                    },
                    onkeyup: move |evt| {
                        let enter_pressed = evt.code() == Code::Enter || evt.code() == Code::NumpadEnter;
                        let shift_key_as_modifier = evt.data.modifiers().contains(Modifiers::SHIFT);

                        if enter_pressed && !shift_key_as_modifier {
                            onreturn.call((text_value_onreturn.borrow().clone(), true, evt.code()));
                        } else if enter_pressed && shift_key_as_modifier {
                            text_value_onkeyup.borrow_mut().push('\n');
                            onchange.call((text_value_onkeyup.borrow().clone(), true));
                        }
                    }
                }
            },
            if *is_disabled && !tooltip.is_empty() {
                cx.render(rsx!(
                    Tooltip {
                        arrow_position: ArrowPosition::None,
                        text: tooltip.clone(),
                    }
                ))
            }
        }
        script { focus_script }
    ))
}
