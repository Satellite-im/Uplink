use dioxus::prelude::*;

use crate::icons::{Icon, IconElement};

const STYLE: &'static str = include_str!("./style.css");

#[derive(Eq, PartialEq)]
pub enum Platform {
    Desktop,
    Mobile,
    Tv,
    Headless
}

impl Platform {
    pub fn to_icon(&self) -> Icon {
        match self {
            Platform::Desktop => Icon::ComputerDesktop,
            Platform::Mobile => Icon::DevicePhoneMobile,
            Platform::Tv => Icon::Tv,
            Platform::Headless => Icon::WrenchScrewdriver
        }
    }
}

#[derive(Eq, PartialEq)]
pub enum Status {
    Online,
    Offline,
    Idle,
    DoNotDistrub,
}

#[derive(Eq, PartialEq, Props)]
pub struct Props {
    platform: Platform,
    status: Status
}

#[allow(non_snake_case)]
pub fn Indicator(cx: Scope<Props>) -> Element {
    let icon = &cx.props.platform;

    cx.render(rsx! (
        style { "{STYLE}" },
        div {
            IconElement {
                icon: icon,
            }
        }
    ))
}