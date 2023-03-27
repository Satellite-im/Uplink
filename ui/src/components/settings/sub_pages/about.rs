use common::language::get_local_text;
use dioxus::prelude::*;

use crate::components::settings::SettingContainer;

#[allow(non_snake_case)]
pub fn AboutPage(cx: Scope) -> Element {
    let version = env!("CARGO_PKG_VERSION");
    // todo: give the executable a better name than "ui"
    let app_name = env!("CARGO_PKG_NAME");
    cx.render(rsx!(
        div {
            id: "settings-about",
            SettingContainer {
                section_label: get_local_text("settings-about.info"),
                div {
                    p {
                        format!("{app_name}: {version}")
                    },
                    p {
                        a {
                            href: "https://satellite.im/",
                            "Website: "
                        },
                        a {
                            href: "https://satellite.im/",
                            u {"https://satellite.im/"},
                        }
                    },
                    p {
                        a {
                            href: "https://github.com/Satellite-im/Uplink",
                            "Source Code: "
                        },
                        a {
                            href: "https://github.com/Satellite-im/Uplink",
                            u {"https://github.com/Satellite-im/Uplink"},
                        }
                    }
                }
            },
        }
    ))
}
