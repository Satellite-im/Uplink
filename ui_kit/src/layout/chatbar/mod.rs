use dioxus::prelude::*;

use crate::{icons::Icon, elements::input::Input};

pub type To = &'static str;

const STYLE: &str = include_str!("./style.css");

#[derive(Clone, PartialEq)]
pub struct Route {
    pub to: To,
    pub icon: Icon,
    pub name: &'static str,
}

#[derive(Props)]
pub struct Props<'a> {
    #[props(optional)]
    with_file_upload: Option<Element<'a>>,
    #[props(optional)]
    extensions: Option<Element<'a>>,
    #[props(optional)]
    controls: Option<Element<'a>>,
}


#[allow(non_snake_case)]
pub fn Chatbar<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    cx.render(
        rsx!(
            style { "{STYLE}" }
            div {
                class: "chatbar",
                &cx.props.with_file_upload,
                Input {
                    placeholder: "Say something...".into(),
                },
                &cx.props.extensions,
                div {
                    class: "controls",
                    &cx.props.controls
                }
            }
        )
    )
}