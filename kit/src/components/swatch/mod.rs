use dioxus::prelude::*;

#[derive(Props)]
pub struct Props<'a> {
    onpress: EventHandler<'a>,
    active: bool,
    color: (u8, u8, u8),
}

#[allow(non_snake_case)]
pub fn ColorSwatch<'a>(props: Props<'a>) -> Element {
    let active = cx
        .props
        .active
        .then(|| "active".to_string())
        .unwrap_or_default();

    rsx!(div {
        class: "color-swatch {active}",
        style: "background-color: rgb({props.color.0}, {props.color.1}, {props.color.2})",
        onclick: |_| props.onpress.call(()),
    }))
}
