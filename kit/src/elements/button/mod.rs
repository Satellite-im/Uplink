use dioxus::{events::MouseEvent, prelude::*};

use crate::elements::Appearance;

use common::icons::outline::Shape as Icon;
use common::icons::IconButton;

#[derive(Props)]
pub struct Props<'a> {
    loading: Option<bool>,
    onpress: Option<EventHandler<'a, MouseEvent>>,
    text: Option<String>,
    tooltip: Option<Element<'a>>,
    aria_label: Option<String>,
    icon: Option<Icon>,
    disabled: Option<bool>,
    appearance: Option<Appearance>,
    with_badge: Option<String>,
    small: Option<bool>,
}

/// Generates the appearance for the button.
/// This will be overwritten if the button is disabled.
pub fn get_appearance(cx: &Scope<Props>) -> Appearance {
    // If the button is disabled, we can short circuit this and just provide the disabled appearance.
    if let Some(is_disabled) = cx.props.disabled {
        if is_disabled {
            return Appearance::Disabled;
        }
    }
    cx.props.appearance.unwrap_or(Appearance::Default)
}

/// Returns a button element generated based on given props.
///
/// # Examples
/// ```no_run
/// use kit::{Icon, tooltip::{Tooltip, ArrowPosition}, components::nav::{Nav, Route}};
///
/// Button {
///     appearance: Appearance::Primary,
///     icon: Icon::Cog6Tooth,
///     tooltip: cx.render(rsx!(
///         Tooltip {
///             arrow_position: ArrowPosition::Bottom,
///             text: String::from("Settings")
///         }
///     )),
/// },
/// ```
#[allow(non_snake_case)]
pub fn Button<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let text = cx.props.text.clone().unwrap_or_default();
    let text2 = text.clone();
    let aria_label = cx.props.aria_label.clone().unwrap_or_default();
    let badge = cx.props.with_badge.clone().unwrap_or_default();
    let disabled = cx.props.disabled.unwrap_or_default();
    let appearance = get_appearance(&cx);
    let small = cx.props.small.unwrap_or_default();

    let tooltip_visible = use_state(cx, || false);

    let button_class = format!(
        "btn appearance-{} btn-{} {} {}",
        appearance,
        if disabled { "btn-disabled" } else { "" },
        if text.is_empty() { "no-text" } else { "" },
        if cx.props.loading.unwrap_or(false) {
            "progress"
        } else {
            ""
        }
    );

    cx.render(
        rsx!(
            div {
                class: {
                    format_args!("btn-wrap {} {}", if disabled { "disabled" } else { "" }, if small { "small" } else { "" })
                },
                onmouseenter: move |_| {
                    if cx.props.tooltip.is_some() {
                         tooltip_visible.set(true);
                    }
                },
                onmouseleave: move |_| {
                    if cx.props.tooltip.is_some() {
                         tooltip_visible.set(false);
                    }
                },
                if *tooltip_visible.current() {
                    cx.props.tooltip.as_ref().map(|tooltip| {
                        rsx!(
                           tooltip
                        )
                    })
                }
                (!badge.is_empty()).then(|| rsx!(
                    span {
                        aria_label: "Button Badge",
                        class: "badge",
                        "{badge}" 
                    }
                )),
                match cx.props.icon {
                    Some(_icon) => {
                        rsx!(
                            IconButton {
                                aria_label: cx.props.aria_label.clone().unwrap_or_default(),
                                title: "{text}",
                                disabled: cx.props.disabled.unwrap_or_default(),
                                class: button_class,
                                onclick: move |e: MouseEvent| {
                                    if !cx.props.disabled.unwrap_or_default() {
                                        let _ = cx.props.onpress.as_ref().map(|f| f.call(e));
                                    }
                                },
                                icon: _icon,
                                children: cx.props.text.clone().map(|text2| cx.render(rsx!( "{text2}" ))),
                            }
                        )
                    },
                    None => {
                        rsx!(
                            button {
                                aria_label: "{aria_label}",
                                title: "{text}",
                                disabled: if disabled { "true" } else { "false" },
                                class: "{button_class}",
                                // Optionally pass through click events.
                                onclick: move |e| {
                                    if !cx.props.disabled.unwrap_or_default() {
                                        let _ = cx.props.onpress.as_ref().map(|f| f.call(e));
                                    }
                                },
                                // We only need to include the text if it contains something.
                                (!text.is_empty()).then(|| rsx!( "{text2}" )),
                            }
                        )
                    }
                }
            },
        )
    )
}
