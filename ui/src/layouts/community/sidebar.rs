use common::icons::outline::Shape as Icon;
use common::state::Action;
use common::state::State;
use dioxus::prelude::*;
use dioxus_router::*;
use kit::elements::input::Input;
use kit::elements::input::Options;
use kit::{components::nav::Nav, layout::sidebar::Sidebar as ReusableSidebar};

use crate::components::chat::RouteInfo;
use crate::components::community::sidebar::SidebarInner;

#[derive(PartialEq, Props)]
pub struct Props {
    route_info: RouteInfo,
}

#[allow(non_snake_case)]
pub fn Sidebar(cx: Scope<Props>) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let router: &std::rc::Rc<RouterService> = use_router(cx);

    cx.render(rsx!(ReusableSidebar {
        hidden: state.read().ui.sidebar_hidden,
        with_search: cx.render(rsx!(
            div {
                class: "search-input",
                Input {
                    placeholder: "Search Community".into(),
                    aria_label: "settings-search-input".into(),
                    icon: Icon::MagnifyingGlass,
                    disabled: true,
                    options: Options {
                        with_clear_btn: true,
                        ..Options::default()
                    }
                }
            }
        )),
        with_nav: cx.render(rsx!(Nav {
            routes: cx.props.route_info.routes.clone(),
            active: cx.props.route_info.active.clone(),
            onnavigate: move |r| {
                if state.read().configuration.audiovideo.interface_sounds {
                    common::sounds::Play(common::sounds::Sounds::Interaction);
                }
                if state.read().ui.is_minimal_view() {
                    state.write().mutate(Action::SidebarHidden(true));
                }
                router.replace_route(r, None, None);
            }
        })),
        SidebarInner {}
    }))
}
