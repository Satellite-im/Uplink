use std::fmt;

use dioxus::prelude::*;
use uuid::Uuid;

const STYLE: &str = include_str!("./style.css");

#[derive(PartialEq, Eq, Copy, Clone)]
/// Which direction will the arrow on the popup point?
pub enum ArrowPosition {
    TopLeft,
    Top,
    TopRight,
    Left,
    Right,
    BottomLeft,
    Bottom,
    BottomRight,
}

impl fmt::Display for ArrowPosition {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            ArrowPosition::TopLeft => write!(f, "arrow-top-left"),
            ArrowPosition::Top => write!(f, "arrow-top"),
            ArrowPosition::TopRight => write!(f, "arrow-top-right"),
            ArrowPosition::Left => write!(f, "arrow-left"),
            ArrowPosition::Right => write!(f, "arrow-right"),
            ArrowPosition::BottomLeft => write!(f, "arrow-bottom-left"),
            ArrowPosition::Bottom => write!(f, "arrow-bottom"),
            ArrowPosition::BottomRight => write!(f, "arrow-bottom-right")
        }
    }
}

/// Generates the arrow_position for the tooltip.
pub fn get_arrow_position(cx: &Scope<Props>) -> String {
    match &cx.props.arrow_position {
        Some(arrow_position) => arrow_position.to_string(),
        None => ArrowPosition::Bottom.to_string(),
    }
}

// Remember: owned props must implement PartialEq!
#[derive(PartialEq, Eq, Props)]
pub struct Props {
    #[props(optional)]
    loading: Option<bool>,
    #[props(optional)]
    text: Option<String>,
    #[props(optional)]
    arrow_position: Option<ArrowPosition>,
}

#[allow(non_snake_case)]
pub fn Tooltip(cx: Scope<Props>) -> Element {
    // You don't always need a UUID. It's used in this case because although the tooltip has generic styles, it needs a unique identifier for runtime actions.
    let UUID: String = Uuid::new_v4().to_string();
    
    let arrow_position = get_arrow_position(&cx);
    let text = match cx.props.text.clone() {
        Some(t) => t,
        None => String::from(""),
    };

    cx.render(rsx! {
        style { "{STYLE}" },
        div {
            class: {
                format_args!("tooltip hidden tooltip-{} tooltip-{}", &UUID, arrow_position)
            },
            span { class: "tooltip-text", "{text}" }
        }
    })
}
