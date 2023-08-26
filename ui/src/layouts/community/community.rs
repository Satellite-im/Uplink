use crate::{
    components::chat::RouteInfo,
    layouts::{community::sidebar::Sidebar, slimbar::SlimbarLayout},
};

use dioxus::prelude::*;

#[derive(PartialEq, Props)]
pub struct Props {
    route_info: RouteInfo,
}

#[allow(non_snake_case)]
pub fn CommunityLayout(cx: Scope<Props>) -> Element {
    cx.render(rsx!(
        div {
            id: "communities-layout",
            aria_label: "communities-layout",
            SlimbarLayout {
                route_info: cx.props.route_info.clone()
            },
            Sidebar {
                route_info: cx.props.route_info.clone()
            }
        }
    ))
}
