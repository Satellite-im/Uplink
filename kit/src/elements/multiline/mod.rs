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
    _onchange: Option<EventHandler<String>>,
    #[props(optional)]
    _onreturn: Option<EventHandler<String>>,
}

#[allow(non_snake_case)]
pub fn Multiline<'a>(props: Props<'a>) -> Element {
    let default_text = props
        .default_text
        .clone()
        .unwrap_or_else(|| "Placeholder...".to_owned());

    rsx! (
        div {
            class: "multiline",
            Input {
                placeholder: props.placeholder.clone(),
                default_text: default_text,
                icon: props.icon.unwrap_or(Icon::QuestionMarkCircle),
                options: props.options.clone().unwrap_or_default(),

            }
        }
    )
}
