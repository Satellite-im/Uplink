use dioxus::prelude::*;
use dioxus_desktop::use_eval;

use crate::elements::button::Button;
use crate::elements::Appearance;

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
    let hidden = cx.props.hidden.unwrap_or(false);
    let minimal = use_state(cx, || false);
    // Run the script after the component is mounted
    let eval = use_eval(cx);
    use_effect(cx, (), |_| {
        to_owned![eval];
        async move {
            eval(SCRIPT.to_string());
        }
    });

    let hamburger = cx.render(rsx!(Button {
        icon: Icon::Bars3,
        appearance: Appearance::Transparent,
        small: true,
        onpress: move |_| { minimal.set(!minimal.get()) }
    }));

    cx.render(rsx!(
        div {
            class: {
                format_args!("sidebar resize-horiz-right {} {}", if hidden { "hidden" } else { "" }, if *minimal.get() { "minimal" } else { "" })
            },
            aria_label: "sidebar",
            match minimal.get() {
                false => {
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
                true => {
                    rsx!(
                        div {
                            class: "hamburger minimal",
                            hamburger
                        }
                    )
                }
            }
        },
    ))
}
