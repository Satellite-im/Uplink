pub mod button {
    use std::fmt;

    use uuid::Uuid;

    use dioxus::{prelude::*, core::UiEvent, events::{MouseData, MouseEvent}};
    use dioxus_heroicons::{outline::Shape, Icon};

    const VARS: &'static str = include_str!("../styles.css");
    const STYLES: &'static str = include_str!("./styles.css");
    const SCRIPT: &'static str = include_str!("./script.js");

    #[derive(Clone, PartialEq)]
    /// Decides the look and feel of a button, also modifies some functionality.
    pub enum Appearance {
        Default,
        Primary,
        Secondary,
        Success,
        Danger,
        Disabled,
    }

    impl fmt::Display for Appearance {
        fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
            match self {
                Appearance::Default => write!(f, "default"),
                Appearance::Primary => write!(f, "primary"),
                Appearance::Secondary => write!(f, "secondary"),
                Appearance::Success => write!(f, "success"),
                Appearance::Danger => write!(f, "danger"),
                Appearance::Disabled => write!(f, "disabled")
            }
        }
    }

    #[derive(Props)]
    pub struct Props<'a> {
        #[props(optional)]
        onpress: Option<EventHandler<'a, MouseEvent>>,
        #[props(optional)]
        text: Option<String>,
        #[props(optional)]
        tooltip: Option<Element<'a>>,
        #[props(optional)]
        icon: Option<Shape>,
        #[props(optional)]
        disabled: Option<bool>,
        #[props(optional)]
        appearance: Option<Appearance>,
    }

    /// Generates the optional text for the button.
    /// If there is no text provided, we'll return an empty string.
    pub fn get_text(cx: &Scope<Props>) -> String {
        match &cx.props.text {
            Some(val) => val.to_owned(),
            None => String::from(""),
        }
    }

    /// Generates the optional icon providing a fallback.
    /// If there is no icon provided, the button should not call this.
    pub fn get_icon(cx: &Scope<Props>) -> Shape {
        match &cx.props.icon {
            Some(icon) => icon.to_owned(),
            None => Shape::QuestionMarkCircle,
        }
    }

    /// Generates the appearance for the button.
    /// This will be overwritten if the button is disabled.
    pub fn get_appearence(cx: &Scope<Props>) -> String {
        // If the button is disabled, we can short circut this and just provide the disabled appearance.
        if cx.props.disabled.is_some() {
            return Appearance::Disabled.to_string();
        }
        match &cx.props.appearance {
            Some(appearance) => appearance.to_string(),
            None => Appearance::Default.to_string(),
        }
    }

    /// Tells the parent the button was interacted with.
    pub fn emit(cx: &Scope<Props>, e: UiEvent<MouseData>) {
        match &cx.props.onpress {
            Some(f) => f.call(e),
            None => {},
        }
    }

    #[allow(non_snake_case)]
    pub fn Button<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
        let UUID: String = Uuid::new_v4().to_string();
        
        let styles: String = STYLES.replace(".btn", &format!(".btn-{}", &UUID));
        // This is needed because you can't have hyphens in javascript declarations.
        let mut SAFE_UUID: String = UUID.clone().replace("-", "_");
        let script: String = SCRIPT.replace("DIUU", &UUID).replace("SAFE_UUID", &SAFE_UUID);

        let text = get_text(&cx);
        let disabled = &cx.props.disabled.unwrap_or(false);
        let appearance = get_appearence(&cx);

        cx.render(
            rsx!(
                style { "{VARS}", "{styles}" },
                div {
                    style: "position: relative; display: inline-flex; justify-content: center;",
                    (cx.props.tooltip.is_some()).then(|| rsx!(
                        &cx.props.tooltip
                    )),
                    button {
                        key: "{UUID}",
                        id: "{UUID}",
                        title: "{text}",
                        disabled: "{disabled}",
                        class: {
                            format_args!("btn appearance-{} btn-{}", appearance, &UUID)
                        },
                        // Optionally pass through click events.
                        onclick: move |e| emit(&cx, e),
                        // If an icon was provided, render it before the text.
                        (&cx.props.icon.is_some()).then(|| rsx!(
                            Icon { 
                                icon: get_icon(&cx)
                            }
                        )),
                        // We only need to include the text if it contains something.
                        (!text.is_empty()).then(|| rsx!( "{text}" )),
                    }
                },
                script{ "{script}" },
            )
        )
    }
}