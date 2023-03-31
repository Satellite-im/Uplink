use common::language::get_local_text;
use dioxus::prelude::*;

use crate::components::settings::{SettingContainer, SettingSection};

#[allow(non_snake_case)]
pub fn AboutPage(cx: Scope) -> Element {
    let version = env!("CARGO_PKG_VERSION");
    // todo: give the executable a better name than "ui"
    let app_name = env!("CARGO_PKG_NAME");
    cx.render(rsx!(
        div {
            id: "settings-about",
            SettingSection {
                section_label: get_local_text("settings-about.info"),
                section_description: app_name.into(),
            },
            SettingSection {
                section_label:  get_local_text("settings-about.version"),
                section_description: version.into(),
            },
            SettingContainer {
                section_label:  get_local_text("settings-about.website"),
                a {
                    href: "https://satellite.im/",
                    u {"https://satellite.im/"},
                }
            },
            SettingContainer {
                section_label: get_local_text("settings-about.source-code"),
                a {
                    href: "https://github.com/Satellite-im/Uplink",
                    u {"https://github.com/Satellite-im/Uplink"},
                }
            },
        }
    ))
}
