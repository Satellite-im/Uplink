use common::{icons, state::State};
use dioxus::{
    core::Event,
    events::{MouseData, MouseEvent},
    prelude::*,
};
use dioxus_desktop::use_window;
use warp::crypto::DID;

use crate::components::indicator::Indicator;

#[derive(Props)]
pub struct ItemProps<'a> {
    #[props(optional)]
    onpress: Option<EventHandler<'a, MouseEvent>>,
    text: String,
    disabled: Option<bool>,
    #[props(optional)]
    icon: Option<icons::outline::Shape>,
    #[props(optional)]
    danger: Option<bool>,
    should_render: Option<bool>,
    aria_label: Option<String>,
    #[props(optional)]
    children: Option<Element<'a>>,
}

/// Tells the parent the menu was interacted with.
pub fn emit(cx: &Scope<ItemProps>, e: Event<MouseData>) {
    if let Some(f) = cx.props.onpress.as_ref() {
        f.call(e)
    }
}

#[allow(non_snake_case)]
pub fn ContextItem<'a>(cx: Scope<'a, ItemProps<'a>>) -> Element<'a> {
    let should_render = cx.props.should_render.unwrap_or(true);

    if !should_render {
        return None;
    }

    let class = if cx.props.danger.is_some() {
        "context-item danger"
    } else {
        "context-item"
    };

    let disabled: bool = cx.props.disabled.unwrap_or(false);

    let aria_label = cx.props.aria_label.clone().unwrap_or_default();

    if let Some(children) = &cx.props.children {
        cx.render(rsx!(div {
            class: "context-item simple-context-item",
            children
        }))
    } else {
        cx.render(rsx!(
            button {
                class: format_args!("{class} {}", if disabled {"context-item-disabled"} else {""}),
                aria_label: "{aria_label}",
                onclick: move |e| {
                    if !disabled {
                        emit(&cx, e);
                    }
                },
                (cx.props.icon.is_some()).then(|| {
                    let icon = cx.props.icon.unwrap_or(icons::outline::Shape::Cog6Tooth);
                    rsx! {
                        icons::Icon { icon: icon }
                    }
                }),
                div {"{cx.props.text}"}
            }
        ))
    }
}

#[derive(PartialEq, Props)]
pub struct IdentityProps {
    sender_did: DID,
}

#[allow(non_snake_case)]
pub fn IdentityHeader(cx: Scope<IdentityProps>) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let sender = state
        .read()
        .get_identity(&cx.props.sender_did)
        .unwrap_or_default();
    let image = sender.profile_picture();
    let banner = sender.profile_banner();
    cx.render(rsx!(
        div {
            class: "identity-header",
            aria_label: "identity-header",
            div {
                id: "banner-image",
                aria_label: "banner-image",
                style: "background-image: url('{banner}');",
                div {
                    id: "profile-image",
                    aria_label: "profile-image",
                    style: "background-image: url('{image}');",
                    Indicator {
                        status: sender.identity_status().into(),
                        platform: sender.platform().into(),
                    }
                }
            }
        }
    ))
}

#[derive(Props)]
pub struct Props<'a> {
    id: String,
    items: Element<'a>,
    children: Element<'a>,
    #[props(optional)]
    devmode: Option<bool>,
    on_mouseenter: Option<EventHandler<'a, MouseEvent>>,
}

#[allow(non_snake_case)]
pub fn ContextMenu<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let id = &cx.props.id;
    let window = use_window(cx);

    // Handles the hiding and showing of the context menu
    let eval = use_eval(cx);
    use_effect(cx, (id,), |(id,)| {
        to_owned![eval];
        async move {
            let script = include_str!("./context.js").replace("UUID", &id);
            let _ = eval(&script);
        }
    });

    cx.render(rsx! {
        div {
            class: "context-wrap",
            onmouseenter: |e| {
                if let Some(f) = cx.props.on_mouseenter.as_ref() { f.call(e) }
            },
            div {
                id: "{id}",
                class: "context-inner",
                &cx.props.children,
            },
            div {
                id: "{id}-context-menu",
                class: "context-menu hidden",
                aria_label: "Context Menu",
                &cx.props.items,
                cx.props.devmode.is_some().then(|| rsx!(
                    hr {},
                    ContextItem {
                        icon: icons::outline::Shape::CommandLine,
                        text: String::from("Open Console"),
                        onpress: move |_| window.devtool(),
                    }
                ))
            },
        },
    })
}
