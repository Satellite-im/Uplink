use dioxus::prelude::*;

use crate::extensions::browser::browser::ExtensionsBrowser;

#[allow(non_snake_case)]
pub fn ExtensionSettings(cx: Scope) -> Element {
    cx.render(rsx!(div {
        id: "settings-extensions",
        aria_label: "settings-extensions",
        ExtensionsBrowser {},
    }))
}
