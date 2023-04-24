use derive_more::Display;
use dioxus::prelude::*;

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

// Remember: owned props must implement PartialEq!
#[derive(PartialEq, Eq, Props)]
pub struct Props {
    loading: Option<bool>,
    text: Option<String>,
    arrow_position: Option<ArrowPosition>,
}

#[allow(non_snake_case)]
pub fn Tooltip(cx: Scope<Props>) -> Element {
    let arrow_position = cx.props.arrow_position.unwrap_or(ArrowPosition::Bottom);
    let text = cx.props.text.clone().unwrap_or_default();

    cx.render(rsx! {
        div {
            aria_label: "tooltip",
            class: {
                format_args!("tooltip tooltip-{}", arrow_position)
            },
            span { aria_label: "tooltip-text", class: "tooltip-text", "{text}" }
        }
    })
}
