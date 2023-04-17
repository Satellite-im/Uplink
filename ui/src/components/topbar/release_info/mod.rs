use common::icons::outline::Shape as Icon;
use common::icons::Icon as IconElement;
use common::language::get_local_text;
use dioxus::prelude::*;

#[allow(non_snake_case)]
pub fn Release_Info(cx: Scope) -> Element {
    let pre_release_text = get_local_text("uplink.pre-release");

    #[cfg(target_os = "macos")]
    let left_padding = true;

    cx.render(rsx!(
        div {
            id: "pre-release",
            class : {
                if left_padding == true {"topbar-item mac-spacer"}  else {"topbar-item"}
            },
            aria_label: "pre-release",
            IconElement {
                icon: Icon::Beaker,
            },
            p {
                div {
                    onclick: move |_| {
                        let _ = open::that("https://issues.satellite.im");
                    },
                    "{pre_release_text}"
                }

            }
        },
    ))
}
