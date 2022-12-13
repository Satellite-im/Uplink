use dioxus::prelude::*;

#[allow(non_snake_case)]
pub fn DeveloperSettings(cx: Scope) -> Element {
    cx.render(rsx!(
        div {
            id: "settings-developer",
            p {
                "Settings Content Developer Page"
            }
        }
    ))
}
