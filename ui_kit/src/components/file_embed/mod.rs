use crate::elements::Appearance;
use crate::elements::button::Button;
use crate::icons::{Icon, IconElement};

use dioxus::prelude::*;

use humansize::format_size;
use humansize::DECIMAL;

#[derive(PartialEq, Props)]
pub struct Props {
    #[props(optional)]
    filename: Option<String>,
    #[props(optional)]
    filesize: Option<u32>,
    #[props(optional)]
    kind: Option<String>,
    #[props(optional)]
    remote: Option<bool>,
    #[props(optional)]
    icon: Option<Icon>,
}

pub fn get_icon(cx: &Scope<Props>) -> Icon {
    match &cx.props.icon {
        Some(icon) => icon.to_owned(),
        None => Icon::QuestionMarkCircle,
    }
}

#[allow(non_snake_case)]
pub fn FileEmbed(cx: Scope<Props>) -> Element {    
    let filename = cx.props.filename.clone().unwrap_or_default();
    let kind = cx.props.kind.clone().unwrap_or_default();
    let filesize = cx.props.filesize.unwrap_or_default();
    let filesize_str = format_size(filesize, DECIMAL);
    let remote = cx.props.remote.unwrap_or_default();

    cx.render(rsx! (
        div {
            class: {
                format_args!(
                    "file-embed {}",
                    if remote {
                        "remote"
                    } else { "" }
                )
            },
            div {
                class: "icon",
                IconElement {
                    icon: get_icon(&cx)
                },
            }
            div {
                class: "file-info",
                p {
                    class: "name",
                    "{filename}"
                },
                p {
                    class: "meta",
                    "{kind} - {filesize_str}"
                }
            },
            Button {
                icon: Icon::ArrowDown,
                appearance: Appearance::Primary,
            }
        }
    ))
}