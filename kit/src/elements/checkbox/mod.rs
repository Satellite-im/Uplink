use dioxus::prelude::*;

#[derive(Props)]
pub struct Props<'a> {
    // returns true if the box is selected, false otherwise
    on_click: Option<EventHandler<'a, bool>>,
}

#[allow(non_snake_case)]
pub fn Checkbox<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    None
}
