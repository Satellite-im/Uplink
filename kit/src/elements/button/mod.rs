use uuid::Uuid;

use dioxus::{events::MouseEvent, prelude::*};

use crate::{elements::Appearance, get_script};

use common::icons::outline::Shape as Icon;
use common::icons::IconButton;

const SCRIPT: &str = include_str!("./script.js");

#[derive(Props)]
pub struct Props<'a> {
    #[props(optional)]
    loading: Option<bool>,
    #[props(optional)]
    onpress: Option<EventHandler<'a, MouseEvent>>,
    #[props(optional)]
    text: Option<String>,
    #[props(optional)]
    tooltip: Option<Element<'a>>,
    #[props(optional)]
    aria_label: Option<String>,
    #[props(optional)]
    icon: Option<Icon>,
    #[props(optional)]
    disabled: Option<bool>,
    #[props(optional)]
    appearance: Option<Appearance>,
    #[props(optional)]
    with_badge: Option<String>,
    #[props(optional)]
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
    let UUID = &*cx.use_hook(|| Uuid::new_v4().to_string());

    let text = cx.props.text.clone().unwrap_or_default();
    let aria_label = cx.props.aria_label.clone().unwrap_or_default();
    let badge = cx.props.with_badge.clone().unwrap_or_default();
    let disabled = cx.props.disabled.unwrap_or_default();
    let appearance = get_appearance(&cx);
    let small = cx.props.small.unwrap_or_default();
    let text2 = text.clone();

    let eval = dioxus_desktop::use_eval(cx);
    // only run this after the component has been mounted
    use_effect(cx, (UUID,), move |(UUID,)| {
        to_owned![eval];
        async move {
            let script = get_script(SCRIPT, &UUID);
            eval(script);
        }
    });

    cx.render(
        rsx!(
            div {
                class: {
                    format_args!("btn-wrap {} {}", if disabled && cx.props.tooltip.is_none() { "disabled" } else { "" }, if small { "small" } else { "" })
                },
                cx.props.tooltip.as_ref().map(|tooltip| rsx!(
                    tooltip
                )),
                (!badge.is_empty()).then(|| rsx!(
                    span {
                        aria_label: "Button Badge",
                        class: "badge",
                        "{badge}" 
                    }
                )),
                button {
                    id: "{UUID}",
                    aria_label: "{aria_label}",
                    title: "{text}",
                    disabled: if disabled && cx.props.tooltip.is_none() { "true" } else { "false" },
                    class: {
                        format_args!(
                            "btn appearance-{} btn-{} {} {} {}", 
                            appearance,
                            UUID,
                            if disabled { "btn-disabled" } else { "" }, 
                            if text.is_empty() { "no-text" } else {""},
                            if cx.props.loading.unwrap_or(false) { "progress" } else { "" }
                        )
                    },
                    // Optionally pass through click events.
                    onclick: move |e| {
                        if !cx.props.disabled.unwrap_or_default() {
                            let _ = cx.props.onpress.as_ref().map(|f| f.call(e));
                        }
                    },
                    // If an icon was provided, render it before the text.
                    (cx.props.icon.is_some()).then(|| rsx!(
                        IconButton {
                            onclick: move |e: MouseEvent| {
                                e.stop_propagation();
                                if !cx.props.disabled.unwrap_or_default() {
                                    let _ = cx.props.onpress.as_ref().map(|f| f.call(e));
                                }
                            },
                            icon: cx.props.icon.unwrap_or(Icon::QuestionMarkCircle),
                        }
                    )),
                    // We only need to include the text if it contains something.
                    (!text.is_empty()).then(|| rsx!( "{text2}" )),
                }
            },
        )
    )
}
