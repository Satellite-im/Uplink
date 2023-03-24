use common::language::get_local_text;
use dioxus::prelude::*;

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
                section_description: format!("{app_name}: {version}"),
            },
        }
    ))
}
