use dioxus::prelude::*;

#[derive(Props)]
pub struct Props<'a> {
    tooltip: Element<'a>,
    children: Element<'a>,
}

// TODO: Right now this component only displays tooltips below the wrapped component, in the future we should expand this component to support tooltip positions.

#[allow(non_snake_case)]
pub fn TooltipWrap<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    cx.render(rsx!(div {
        class: "tooltip-parent",
        div {
            class: "tooltip-wrapper",
            cx.props.tooltip.as_ref()
        }
        cx.props.children.as_ref()
    }))
}
