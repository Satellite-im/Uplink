use common::icons::outline::Shape as Icon;
use dioxus::prelude::*;
use kit::elements::button::Button;
use kit::elements::Appearance;
use tracing::log;

use crate::components::settings::SettingSection;

#[allow(non_snake_case)]
pub fn Licenses() -> Element {
    log::trace!("Licenses settings page rendered.");
    const MIT_URL: &str = "https://github.com/Satellite-im/Uplink/blob/dev/LICENSE";

    rsx!(
        div {
            id: "settings-licenses",
            aria_label: "settings-licenses",
            SettingSection {
                aria_label: "licenses-section".into(),
                section_label: "Uplink".into(),
                section_description: "Both code and icons are under the MIT license.".into(),
                Button {
                    aria_label: "licenses-button".into(),
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
    )
}
