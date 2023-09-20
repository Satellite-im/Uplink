pub mod sidebar;

use crate::layouts::{community::sidebar::Sidebar, slimbar::SlimbarLayout};

use dioxus::prelude::*;
use kit::components::{community::card::CommunityCard, user::card::UserCard};

#[allow(non_snake_case)]
pub fn CommunityLayout(cx: Scope) -> Element {
    // TODO: Placeholder data
    let joined = use_state(cx, || false);
    let friends = use_state(cx, || false);
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
            div {
                id: "community-content",
                CommunityCard {
                    joined: *joined.get(),
                    name: "Rust".into(),
                    onjoin: |_| {
                        joined.set(true);
                    }
                },
                UserCard {
                    friends: *friends.get(),
                    name: "XileHorizon".into(),
                    status: "To infinity and then some.".into(),
                    onjoin: |_| {
                        friends.set(true);
                    }
                }
            }
        }
    ))
}
