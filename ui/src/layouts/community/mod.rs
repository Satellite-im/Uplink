pub mod sidebar;

use crate::layouts::{community::sidebar::Sidebar, slimbar::SlimbarLayout};

use dioxus::prelude::*;
use kit::components::{community::card::CommunityCard, user::card::UserCard};

#[allow(non_snake_case)]
pub fn CommunityLayout() -> Element {
    // TODO: Placeholder data
    let joined = use_signal(|| false);
    let friends = use_signal(|| false);
    rsx!(
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
                    joined: joined(),
                    name: "Rust".to_string(),
                    onjoin: |_| {
                        joined.set(true);
                    }
                },
                UserCard {
                    friends: friends(),
                    name: "XileHorizon".to_string(),
                    status: "To infinity and then some.".to_string(),
                    onjoin: |_| {
                        friends.set(true);
                    }
                }
            }
        }
    )
}
