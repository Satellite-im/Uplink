use dioxus::prelude::*;

use crate::elements::folder::Folder;

#[derive(Props)]
pub struct Props<'a> {
    onsubmit: Option<EventHandler<'a, String>>,
}

/// Tells the parent the button was interacted with.
pub fn emit(cx: &Scope<Props>, s: String) {
    match &cx.props.onsubmit {
        Some(f) => f.call(s),
        None => {}
    }
}

#[allow(non_snake_case)]
pub fn NewFolder<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    cx.render(rsx!(
        div {
            Folder {
                with_rename: true,
                onrename: |val| {

                }
            }
        }
    ))
}
