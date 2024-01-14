#[allow(unused_imports)]
use std::collections::{BTreeMap, HashMap, HashSet};

use common::state::State;
use dioxus::prelude::*;
use kit::elements::switch::Switch;

use crate::components::settings::SettingSectionSimple;

#[allow(non_snake_case)]
pub fn GroupSettings(cx: Scope) -> Element {
    log::trace!("rendering edit_group");
    let state = use_shared_state::<State>(cx)?;

    cx.render(rsx!(
        div {
            id: "group-settings",
            aria_label: "group-settings",
            div {
                class: "settings",
                SettingSectionSimple {
                    aria_label: "allow-members-to-add-others".into(),
                    p {
                        "Allow anyone to add members"
                    }
                    Switch {}
                },
                SettingSectionSimple {
                    aria_label: "allow-members-to-add-edit-name".into(),
                    p {
                        "Allow anyone to rename group"
                    }
                    Switch {}
                },
            }
        }
    ))
}
