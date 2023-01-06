use std::fmt;

use dioxus::prelude::*;

use crate::icons::{Icon, IconElement};

#[derive(Eq, PartialEq, Clone, Copy)]
pub enum Platform {
    // The user is using a desktop computer
    Desktop,

    // The user is using a mobile device
    Mobile,

    // The user is using a television
    Tv,

    // The user is using a headless device (e.g. a server)
    Headless,
}

impl Platform {
    // Convert a Platform value to an Icon value
    pub fn to_icon(&self) -> Icon {
        match self {
            Platform::Desktop => Icon::Circle,
            Platform::Mobile => Icon::DevicePhoneMobile,
            Platform::Tv => Icon::Tv,
            Platform::Headless => Icon::WrenchScrewdriver,
        }
    }
}

impl fmt::Display for Platform {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        let s = match self {
            Platform::Desktop => String::from("circle"),
            Platform::Mobile => String::from("mobile"),
            Platform::Tv => String::from("tv"),
            Platform::Headless => String::from("headless"),
        };
        write!(f, "{s}")
    }
}

#[derive(Eq, PartialEq, Clone, Copy)]
pub enum Status {
    // The user is currently online
    Online,

    // The user is currently offline
    Offline,

    // The user is currently idle
    Idle,

    // The user has enabled do-not-disturb mode
    DoNotDisturb,
}

impl fmt::Display for Status {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Status::Online => write!(f, "online"),
            Status::Offline => write!(f, "offline"),
            Status::Idle => write!(f, "idle"),
            Status::DoNotDisturb => write!(f, "do-not-disturb"),
        }
    }
}

#[derive(Eq, PartialEq, Props)]
pub struct Props {
    // Whether the indicator is in a loading state
    #[props(optional)]
    loading: Option<bool>,

    // The platform the user is using
    platform: Platform,

    // The user's online status
    status: Status,
}

#[allow(non_snake_case)]
pub fn Indicator(cx: Scope<Props>) -> Element {
    let icon = cx.props.platform.to_icon();
    let status = cx.props.status.to_string();

    cx.render(rsx!(div {
        class: "indicator indicator-{status}",
        IconElement {
            icon: icon,
            class: "{cx.props.platform.to_string()}"
        }
    }))
}
