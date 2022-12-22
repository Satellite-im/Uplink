use dioxus::prelude::*;
use dioxus_desktop::{
    tao::dpi::{LogicalSize, Size},
    use_window,
};

#[allow(non_snake_case)]
pub fn UnlockLayout(cx: Scope) -> Element {
    let window = use_window(&cx);
    // window.set_inner_size(Size::Logical(LogicalSize {
    //     width: 100.0,
    //     height: 100.0,
    // }));

    cx.render(rsx!(
        div {
            id: "files-layout",
            "Unlock"
        }
    ))
}
