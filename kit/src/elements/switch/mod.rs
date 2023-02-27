use dioxus::prelude::*;

// Remember: owned props must implement PartialEq!
#[derive(Props)]
pub struct Props<'a> {
    #[props(optional)]
    _loading: Option<bool>,
    #[props(optional)]
    disabled: Option<bool>,
    #[props(optional)]
    active: Option<bool>,
    #[props(optional)]
    onflipped: Option<EventHandler<'a, bool>>,
}

/// Tells the parent the switch was interacted with.
pub fn emit(cx: &Scope<Props>, state: bool) {
    match &cx.props.onflipped {
        Some(f) => f.call(state),
        None => {}
    }
}

/// Determines the default state
pub fn default_state(cx: &Scope<Props>) -> bool {
    match &cx.props.active {
        Some(active) => *active,
        None => false,
    }
}

#[allow(non_snake_case)]
pub fn Switch<'a>(cx: Scope<'a, Props>) -> Element<'a> {
    let checked_state = default_state(&cx);
    let disabled = cx.props.disabled.unwrap_or_default();

    cx.render(rsx! {
        label {
            class: {
                format_args!("switch {}", if disabled { "disabled" } else { "" })
            },
            aria_label: "Switch Slider",
            input {
                aria_label: "switch-slider-value",
                disabled: "{disabled}",
                "type": "checkbox",
                checked: "{checked_state}",
                oninput: move |e| emit(&cx, e.data.value == "true")
            },
            span { class: "slider" }
        }
    })
}
