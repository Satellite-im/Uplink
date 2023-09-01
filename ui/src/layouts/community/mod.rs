pub mod sidebar;

use crate::layouts::{community::sidebar::Sidebar, slimbar::SlimbarLayout};

use dioxus::prelude::*;

#[allow(non_snake_case)]
pub fn CommunityLayout(cx: Scope) -> Element {
    cx.render(rsx!(
        div {
            id: "communities-layout",
            aria_label: "communities-layout",
            SlimbarLayout {
                active: crate::UplinkRoute::CommunityLayout {}
            },
            Sidebar {
                active: crate::UplinkRoute::CommunityLayout {}
            }
        }
    ))
}
