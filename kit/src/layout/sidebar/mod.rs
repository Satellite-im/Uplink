use crate::elements::button::Button;
use crate::elements::Appearance;
use common::state::{Action, State};
use dioxus::prelude::*;

use common::icons::outline::Shape as Icon;

#[derive(Props, Clone, PartialEq)]
pub struct Props {
    #[props(optional)]
    with_search: Option<Element>,
    #[props(optional)]
    with_nav: Option<Element>,
    with_call_controls: Option<Element>,
    with_file_transfer: Option<Element>,
    #[props(optional)]
    hidden: Option<bool>,
    #[props(optional)]
    children: Option<Element>,
}

#[allow(non_snake_case)]
pub fn Sidebar(props: Props) -> Element {
    let mut state = use_context::<Signal<State>>();
    let hidden = props.hidden.unwrap_or(false);

    let hamburger = rsx!(Button {
        aria_label: "hamburger-button".to_string(),
        icon: Icon::SidebarArrowLeft,
        appearance: Appearance::Transparent,
        onpress: move |_| {
            state.write().mutate(Action::SidebarHidden(true));
        }
    });

    rsx!(
        div {
            class: {
                format_args!("sidebar resize-horiz-right {}", if hidden { "hidden" } else { "" })
            },
            aria_label: "sidebar",
                div {
                    class: "search",
                    aria_label: "sidebar-search",
                    {props.with_search.as_ref()},
                    div {
                        class: "hamburger",
                        {hamburger}
                    }
                },
                div {
                    class: "children disable-select",
                    aria_label: "sidebar-children",
                    {props.children.as_ref()}
                },
                {props.with_file_transfer.as_ref()},
                {props.with_call_controls.as_ref()},
                {props.with_nav.as_ref()},
        },
    )
}
