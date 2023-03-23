use derive_more::Display;
use dioxus::prelude::*;
use uuid::Uuid;

#[derive(PartialEq, Eq, Copy, Clone, Display)]
/// Which direction will the arrow on the popup point?
pub enum ArrowPosition {
    #[display(fmt = "arrow-top-none")]
    None,
    #[display(fmt = "arrow-top-left")]
    TopLeft,

    #[display(fmt = "arrow-top")]
    Top,

    #[display(fmt = "arrow-top-right")]
    TopRight,

    #[display(fmt = "arrow-left")]
    Left,

    #[display(fmt = "arrow-right")]
    Right,

    #[display(fmt = "arrow-bottom-left")]
    BottomLeft,

    #[display(fmt = "arrow-bottom")]
    Bottom,

    #[display(fmt = "arrow-bottom-right")]
    BottomRight,
}

/// Generates the arrow_position for the tooltip.
pub fn get_arrow_position(cx: &Scope<Props>) -> ArrowPosition {
    cx.props.arrow_position.unwrap_or(ArrowPosition::Bottom)
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
    let UUID = cx.use_hook(|| Uuid::new_v4().to_string());

    let arrow_position = get_arrow_position(&cx);

    let text = cx.props.text.clone().unwrap_or_default();

    cx.render(rsx! {
        div {
            aria_label: "tooltip",
            class: {
                format_args!("tooltip hidden tooltip-{} tooltip-{}", &UUID, arrow_position)
            },
            span { aria_label: "tooltip-text", class: "tooltip-text", "{text}" }
        }
    })
}
