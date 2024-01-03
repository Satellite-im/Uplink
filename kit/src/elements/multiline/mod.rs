//! todo: use a contenteditable div for this. see the old version of uplink for an example (which didn't quite work right when rendering markdown)

use dioxus::prelude::*;

use crate::elements::input::Input;
use common::icons::outline::Shape as Icon;

#[derive(Props)]
pub struct Props<'a> {
    #[props(optional)]
    _loading: Option<bool>,
    placeholder: String,
    #[props(optional)]
    default_text: Option<String>,
    #[props(optional)]
    icon: Option<Icon>,
    #[props(optional)]
    options: Option<super::input::Options>,
    #[props(optional)]
    _onchange: Option<EventHandler<'a, String>>,
    #[props(optional)]
    _onreturn: Option<EventHandler<'a, String>>,
}

#[allow(non_snake_case)]
pub fn Multiline<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let default_text = cx
        .props
        .default_text
        .clone()
        .unwrap_or_else(|| "Placeholder...".to_owned());

    cx.render(rsx! (
        div {
            class: "multiline",
            Input {
                placeholder: cx.props.placeholder.clone(),
                default_text: default_text,
                icon: cx.props.icon.unwrap_or(Icon::QuestionMarkCircle),
                options: cx.props.options.clone().unwrap_or_default(),

            }
        }
    ))
}
