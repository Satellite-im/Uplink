use std::fmt;

use dioxus::prelude::*;

use crate::icons::{Icon, IconElement};

const STYLE: &'static str = include_str!("./style.css");

#[derive(Eq, PartialEq, Clone, Copy)]
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

#[derive(Eq, PartialEq, Clone, Copy)]
pub enum Status {
    Online,
    Offline,
    Idle,
    DoNotDistrub,
}

impl fmt::Display for Status {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Status::Online => write!(f, "online"),
            Status::Offline => write!(f, "offline"),
            Status::Idle => write!(f, "idle"),
            Status::DoNotDistrub => write!(f, "do-not-distrub"),
        }
    }
}

#[derive(Eq, PartialEq, Props)]
pub struct Props {
    #[props(optional)]
    loading: Option<bool>,
    platform: Platform,
    status: Status
}

#[allow(non_snake_case)]
pub fn Indicator(cx: Scope<Props>) -> Element {
    let icon = cx.props.platform.to_icon();
    let status = cx.props.status.to_string();

    cx.render(rsx! (
        style { "{STYLE}" },
        div {
            class: "indicator indicator-{status}",
            IconElement {
                icon: icon
            }
        }
    ))
}