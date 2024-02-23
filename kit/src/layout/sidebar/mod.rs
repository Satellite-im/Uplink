use crate::elements::button::Button;
use crate::elements::Appearance;
use common::state::{Action, State};
use dioxus::prelude::*;

use common::icons::outline::Shape as Icon;

#[derive(Props)]
pub struct Props<'a> {
    #[props(optional)]
    with_search: Option<Element>,
    #[props(optional)]
    with_nav: Option<Element>,
    with_call_controls: Option<Element>,
    #[props(optional)]
    hidden: Option<bool>,
    #[props(optional)]
    children: Option<Element>,
}

#[allow(non_snake_case)]
pub fn Sidebar<'a>(props: Props<'a>) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let hidden = props.hidden.unwrap_or(false);

    let hamburger = cx.render(rsx!(Button {
        aria_label: "hamburger-button".into(),
        icon: Icon::SidebarArrowLeft,
        appearance: Appearance::Transparent,
        onpress: move |_| {
            state.write().mutate(Action::SidebarHidden(true));
        }
    }));

    cx.render(rsx!(
        div {
            class: {
                format_args!("sidebar resize-horiz-right {}", if hidden { "hidden" } else { "" })
            },
            aria_label: "sidebar",
            rsx!(
                div {
                    class: "search",
                    aria_label: "sidebar-search",
                    props.with_search.as_ref(),
                    div {
                        class: "hamburger",
                        hamburger
                    }
                },
                div {
                    class: "children disable-select",
                    aria_label: "sidebar-children",
                    props.children.as_ref()
                },
                props.with_call_controls.as_ref(),
                props.with_nav.as_ref(),
            )
        },
    ))
}
