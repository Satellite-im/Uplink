use dioxus::prelude::*;

#[allow(non_snake_case)]
pub fn ExtensionSettings(cx: Scope) -> Element {
    cx.render(rsx!(
        div {
            id: "settings-extensions",
            p {
                "Settings Content Extensions Page"
            }
        }
    ))
}
