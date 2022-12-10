use uuid::Uuid;

use dioxus::{prelude::*, core::UiEvent, events::{MouseData, MouseEvent}};

use crate::{get_styles, get_script, elements::Appearance, icons::{Icon, IconElement}};

const STYLE: &str = include_str!("./style.css");
const SCRIPT: &str = include_str!("./script.js");


#[derive(Props)]
pub struct Props<'a> {
    #[props(optional)]
    _loading: Option<bool>,
    #[props(optional)]
    onpress: Option<EventHandler<'a, MouseEvent>>,
    #[props(optional)]
    text: Option<String>,
    #[props(optional)]
    tooltip: Option<Element<'a>>,
    #[props(optional)]
    icon: Option<Icon>,
    #[props(optional)]
    disabled: Option<bool>,
    #[props(optional)]
    appearance: Option<Appearance>,
    #[props(optional)]
    with_badge: Option<String>
}

/// Generates the optional text for the button.
/// If there is no text provided, we'll return an empty string.
pub fn get_text(cx: &Scope<Props>) -> String {
    match &cx.props.text {
        Some(val) => val.to_owned(),
        None => String::from(""),
    }
}

/// Generates the optional badge for the button.
/// If there is no badge provided, we'll return an empty string.
pub fn get_badge(cx: &Scope<Props>) -> String {
    match &cx.props.with_badge {
        Some(val) => val.to_owned(),
        None => String::from(""),
    }
}

/// Generates the optional icon providing a fallback.
/// If there is no icon provided, the button should not call this.
pub fn get_icon(cx: &Scope<Props>) -> Icon {
    match &cx.props.icon {
        Some(icon) => icon.to_owned(),
        None => Icon::QuestionMarkCircle,
    }
}

/// Generates the appearance for the button.
/// This will be overwritten if the button is disabled.
pub fn get_appearence(cx: &Scope<Props>) -> String {
    // If the button is disabled, we can short circut this and just provide the disabled appearance.
    if cx.props.disabled.is_some() {
        return Appearance::Disabled.to_string();
    }
    match &cx.props.appearance {
        Some(appearance) => appearance.to_string(),
        None => Appearance::Default.to_string(),
    }
}

/// Tells the parent the button was interacted with.
pub fn emit(cx: &Scope<Props>, e: UiEvent<MouseData>) {
    match &cx.props.onpress {
        Some(f) => f.call(e),
        None => {},
    }
}


/// Returns a button element generated based on given props.
/// 
/// # Examples
/// ```no_run
/// use ui_kit::{Icon, tooltip::{Tooltip, ArrowPosition}, components::nav::{Nav, Route}};
/// 
/// Button {
///     appearance: Appearance::Primary,
///     icon: Icon::Cog,
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
    let UUID = Uuid::new_v4().to_string();

    let script = get_script(SCRIPT, &UUID);
    let styles = get_styles(STYLE);

    let text = get_text(&cx);
    let badge = get_badge(&cx);
    let disabled = &cx.props.disabled.unwrap_or(false);
    let appearance = get_appearence(&cx);

    cx.render(
        rsx!(
            style { "{styles}" },
            div {
                style: "position: relative; display: inline-flex; justify-content: center;",
                class: {
                    format_args!("btn-wrap {}", if *disabled { "disabled" } else { "" })
                },
                (cx.props.tooltip.is_some()).then(|| rsx!(
                    &cx.props.tooltip
                )),
                (!badge.is_empty()).then(|| rsx!(
                    span { 
                        class: "badge",
                        "{badge}" 
                    }
                )),
                button {
                    id: "{UUID}",
                    title: "{text}",
                    disabled: "{disabled}",
                    class: {
                        format_args!(
                            "btn appearance-{} btn-{} {} {}", 
                            appearance, 
                            UUID, 
                            if *disabled { "btn-disabled" } else { "" }, 
                            if text.is_empty() { "no-text" } else {""}
                        )
                    },
                    // Optionally pass through click events.
                    onclick: move |e| emit(&cx, e),
                    // If an icon was provided, render it before the text.
                    (cx.props.icon.is_some()).then(|| rsx!(
                        IconElement { 
                            icon: get_icon(&cx)
                        }
                    )),
                    // We only need to include the text if it contains something.
                    (!text.is_empty()).then(|| rsx!( "{text}" )),
                }
            },
            script{ "{script}" },
        )
    )
}
