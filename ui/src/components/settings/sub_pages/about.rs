use common::icons::outline::Shape as Icon;
use common::language::get_local_text;
use dioxus::prelude::*;
use kit::elements::{button::Button, Appearance};

use crate::components::settings::SettingSection;

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
            SettingSection {
                section_label: get_local_text("settings-about.open-website"),
                section_description: get_local_text("settings-about.open-website-description"),
                Button {
                    text: get_local_text("settings-about.open-website"),
                    aria_label: "open-website-button".into(),
                    appearance: Appearance::Secondary,
                    icon: Icon::GlobeAlt,
                    onpress: |_| {
                        let _ = open::that("https://satellite.im");
                    }
                }
            },
            SettingSection {
                section_label: get_local_text("settings-about.open-codebase"),
                section_description: get_local_text("settings-about.open-codebase-description"),
                Button {
                    text: get_local_text("settings-about.open-codebase"),
                    aria_label: "open-codebase-button".into(),
                    appearance: Appearance::Secondary,
                    icon: Icon::CodeBracketSquare,
                    onpress: |_| {
                        let _ = open::that("https://github.com/Satellite-im/Uplink");
                    }
                }
            },
        }
    ))
}
