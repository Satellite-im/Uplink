use dioxus::prelude::*;

#[derive(Props, Clone, PartialEq)]
pub struct Props {
    tooltip: Element,
    children: Element,
}

// TODO: Right now this component only displays tooltips below the wrapped component, in the future we should expand this component to support tooltip positions.

#[allow(non_snake_case)]
pub fn TooltipWrap(props: Props) -> Element {
    let tooltip = props.tooltip.as_ref().clone();
    let children = props.children.as_ref();

    rsx!(div {
        class: "tooltip-parent",
        div {
            class: "tooltip-wrapper",
            {tooltip},
        }
        {children}
    },)
}
