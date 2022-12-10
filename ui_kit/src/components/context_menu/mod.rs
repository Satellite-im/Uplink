use dioxus::{desktop::use_window, prelude::*, core::UiEvent, events::{MouseData, MouseEvent}};
use dioxus_heroicons::outline::Shape;
use uuid::Uuid;

use crate::icons::{Icon, IconElement};

const STYLE: &'static str = include_str!("./style.css");

#[derive(Props)]
pub struct ItemProps<'a> {
    #[props(optional)]
    onpress: Option<EventHandler<'a, MouseEvent>>,
    text: String,
    #[props(optional)]
    icon: Option<Icon>,
    #[props(optional)]
    danger: Option<bool>,
}

/// Tells the parent the menu was interacted with.
pub fn emit(cx: &Scope<ItemProps>, e: UiEvent<MouseData>) {
    match &cx.props.onpress {
        Some(f) => f.call(e),
        None => {},
    }
}

#[allow(non_snake_case)]
pub fn ContextItem<'a>(cx: Scope<'a, ItemProps<'a>>) -> Element<'a> {
    let class = if cx.props.danger.is_some() {
        "context-item danger"
    } else {
        "context-item"
    };
    cx.render(rsx! {
        button {
            class: "{class}",
            onclick: move |e| emit(&cx, e),
            (cx.props.icon.is_some()).then(|| {
                let icon = match cx.props.icon {
                    Some(shape) => shape,
                    None => Shape::Cog,
                };
                rsx! {
                    IconElement { icon: icon }
                }
            }),
            div {"{cx.props.text}"}
        }
    })
}

#[derive(Props)]
pub struct Props<'a> {
    items: Element<'a>,
    children: Element<'a>,
    #[props(optional)]
    devmode: Option<bool>,
}

#[allow(non_snake_case)]
pub fn ContextMenu<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let UUID = Uuid::new_v4().to_string().replace("-", "");

    // Handles the hiding and showing of the context menu
    let script = include_str!("./context.js").replace("UUID", &UUID);

    let id = format!("{}-context-menu", &UUID);
    
    let window = use_window(&cx);

    cx.render(rsx! {
        style { "{STYLE}" },
        div {
            class: "context-wrap",
            div {
                id: "{UUID}",
                style: "width: 100%;",
                &cx.props.children,
            },
            div {
                id: "{id}",
                class: "context-menu hidden",
                &cx.props.items,
                cx.props.devmode.is_some().then(|| rsx!(
                    hr {},
                    ContextItem {
                        icon: Shape::CommandLine,
                        text: String::from("Open Console"),
                        onpress: move |_| window.devtool(),
                    }
                ))
            },
        },
        script { "{script}" }
    })
}
