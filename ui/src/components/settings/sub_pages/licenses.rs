use common::icons::outline::Shape as Icon;
use dioxus::prelude::*;
use kit::elements::button::Button;
use kit::elements::Appearance;
use warp::logging::tracing::log;

use crate::components::settings::SettingSection;

#[allow(non_snake_case)]
pub fn Licenses(cx: Scope) -> Element {
    log::trace!("Licenses settings page rendered.");

    cx.render(rsx!(
        div {
            id: "settings-licenses",
            aria_label: "settings-licenses",
            SettingSection {
                section_label: "heroicons".into(),
                section_description: "We have expanded upon the heroicons library we offer any additional icons under the same license as the original author.".into(),
                Button {
                    text: "MIT".into(),
                    appearance: Appearance::Secondary,
                    icon: Icon::DocumentText,
                    onpress: move |_| {
                        let _ = open::that("https://github.com/tailwindlabs/heroicons/blob/master/LICENSE");
                    }
                }
            },
        }
    ))
}
