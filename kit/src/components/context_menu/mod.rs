use common::icons;
use dioxus::{
    core::Event,
    events::{MouseData, MouseEvent},
    prelude::*,
};
use dioxus_desktop::{use_eval, use_window};

#[derive(Props)]
pub struct ItemProps<'a> {
    #[props(optional)]
    onpress: Option<EventHandler<'a, MouseEvent>>,
    text: String,
    #[props(optional)]
    icon: Option<icons::outline::Shape>,
    #[props(optional)]
    danger: Option<bool>,

    should_render: Option<bool>,
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
    cx.render(rsx! {
        button {
            class: "{class}",
            aria_label: "Context Item",
            onclick: move |e| emit(&cx, e),
            (cx.props.icon.is_some()).then(|| {
                let icon = cx.props.icon.unwrap_or(icons::outline::Shape::Cog6Tooth);
                rsx! {
                    icons::Icon { icon: icon }
                }
            }),
            div {"{cx.props.text}"}
        }
    })
}

#[derive(Props)]
pub struct Props<'a> {
    id: String,
    items: Element<'a>,
    children: Element<'a>,
    #[props(optional)]
    devmode: Option<bool>,
    // messages in the compose window need to detect when they are scrolled,
    // and the onmouseout event fires on the ContextMenu (which every message is wrapped in)
    on_mouseout: Option<EventHandler<'a, MouseEvent>>,
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
            eval(script);
        }
    });

    cx.render(rsx! {
        div {
            class: "context-wrap",
            onmouseout: |e| {
                let _ = cx.props.on_mouseout.as_ref().map(|f| f.call(e));
            },
            div {
                id: "{id}",
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
