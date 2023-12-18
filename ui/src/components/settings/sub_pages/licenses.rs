use common::icons::outline::Shape as Icon;
use dioxus::prelude::*;
use kit::elements::button::Button;
use kit::elements::Appearance;
use warp::logging::tracing::log;

use crate::components::settings::SettingSection;

#[allow(non_snake_case)]
pub fn Licenses(cx: Scope) -> Element {
    log::trace!("Licenses settings page rendered.");
    const MIT_URL: &str = "https://mit-license.org/";

    cx.render(rsx!(
        div {
            id: "settings-licenses",
            aria_label: "settings-licenses",
            SettingSection {
                section_label: "Uplink".into(),
                section_description: "Both code and icons are under the MIT license.".into(),
                Button {
                    text: "License Description".into(),
                    appearance: Appearance::Secondary,
                    icon: Icon::DocumentText,
                    onpress: move |_| {
                        if let Err(e) = open::that(MIT_URL) {
                            log::error!("Failed to open URL {MIT_URL}: {e}");
                        }
                    }
                }
            },
        }
    ))
}
