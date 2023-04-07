use crate::elements::button::Button;
use crate::elements::Appearance;
use common::state::{Action, State};
use dioxus::prelude::*;
use dioxus_desktop::use_eval;

use common::icons::outline::Shape as Icon;

#[derive(Props)]
pub struct Props<'a> {
    #[props(optional)]
    with_search: Option<Element<'a>>,
    #[props(optional)]
    with_nav: Option<Element<'a>>,
    #[props(optional)]
    hidden: Option<bool>,
    #[props(optional)]
    children: Option<Element<'a>>,
}

const SCRIPT: &str = include_str!("./script.js");

#[allow(non_snake_case)]
pub fn Sidebar<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let state = use_shared_state::<State>(cx)?;
    let hidden = cx.props.hidden.unwrap_or(false);
    // Run the script after the component is mounted
    let eval = use_eval(cx);
    use_effect(cx, (), |_| {
        to_owned![eval];
        async move {
            eval(SCRIPT.to_string());
        }
    });

    let hamburger = cx.render(rsx!(Button {
        aria_label: "hamburger-button".into(),
        icon: Icon::Bars3,
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
                    cx.props.with_search.as_ref(),
                    div {
                        class: "hamburger",
                        hamburger
                    }
                },
                div {
                    class: "children",
                    aria_label: "sidebar-children",
                    cx.props.children.as_ref()
                },
                cx.props.with_nav.as_ref(),
            )
        },
    ))
}
