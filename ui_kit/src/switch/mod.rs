pub mod switch {
    use dioxus::prelude::*;

    const STYLES: &'static str = include_str!("./style.css");
    
    // Remember: owned props must implement PartialEq!
    #[derive(Props)]
    pub struct Props<'a> {
        #[props(optional)]
        active: Option<bool>,
        #[props(optional)]
        onflipped: Option<EventHandler<'a, bool>>,
    }


    /// Tells the parent the switch was interacted with.
    pub fn emit(cx: &Scope<Props>, state: bool) {
        match &cx.props.onflipped {
            Some(f) => f.call(state),
            None => {},
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

        cx.render(rsx! {
            style { "{STYLES}" },
            label {
                class: "switch",
                input {
                    "type": "checkbox",
                    checked: "{checked_state}",
                    oninput: move |e| emit(&cx, if e.data.value == "true" { true } else { false })
                },
                span { class: "slider" }
            }
        })
    }
}