use dioxus::prelude::*;

#[allow(non_snake_case)]
pub fn AudioSettings(cx: Scope) -> Element {
    cx.render(rsx!(
        div {
            id: "settings-audio",
            p {
                "Settings Content Audio Page"
            }
        }
    ))
}
