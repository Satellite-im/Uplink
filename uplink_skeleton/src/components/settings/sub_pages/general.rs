use dioxus::prelude::*;

#[allow(non_snake_case)]
pub fn GeneralSettings(cx: Scope) -> Element {
    cx.render(rsx!(
        div {
            id: "settings-general",
            p {
                "Settings Content General Page"
            }
        }
    ))
}
