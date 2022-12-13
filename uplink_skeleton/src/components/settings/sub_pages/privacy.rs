use dioxus::prelude::*;

#[allow(non_snake_case)]
pub fn PrivacySettings(cx: Scope) -> Element {
    cx.render(rsx!(
        div {
            id: "settings-privacy",
            p {
                "Settings Content Privacy Page"
            }
        }
    ))
}
