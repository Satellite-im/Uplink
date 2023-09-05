use common::icons::outline::Shape as Icon;
use common::state::Action;
use common::state::State;
use dioxus::prelude::*;
use kit::elements::input::Input;
use kit::elements::input::Options;
use kit::elements::tooltip::ArrowPosition;
use kit::layout::sidebar::Sidebar as ReusableSidebar;

use crate::components::community::sidebar::SidebarInner;
use crate::UplinkRoute;

#[derive(PartialEq, Props)]
pub struct Props {
    pub active: UplinkRoute,
}

#[allow(non_snake_case)]
pub fn Sidebar(cx: Scope<Props>) -> Element {
    let state = use_shared_state::<State>(cx)?;

    cx.render(rsx!(ReusableSidebar {
        hidden: state.read().ui.sidebar_hidden,
        with_search: cx.render(rsx!(
            div {
                class: "search-input",
                Input {
                    placeholder: "The Uplink Community".into(),
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
        with_nav: cx.render(rsx!(
            crate::AppNav {
                active: cx.props.active.clone(),
                tooltip_direction: ArrowPosition::Left,
                onnavigate: move |_| {
                    if state.read().configuration.audiovideo.interface_sounds {
                        common::sounds::Play(common::sounds::Sounds::Interaction);
                    }
                    if state.read().ui.is_minimal_view() {
                        state.write().mutate(Action::SidebarHidden(true));
                    }
                },
            },
        )),
        SidebarInner {}
    }))
}
