use crate::elements::button::Button;
use crate::elements::Appearance;
use common::icons::outline::Shape as Icon;
use common::icons::Icon as IconElement;

use dioxus::prelude::*;

use humansize::format_size;
use humansize::DECIMAL;

#[derive(PartialEq, Props)]
pub struct Props {
    // The filename of the file
    #[props(optional)]
    filename: Option<String>,

    // The size of the file in bytes
    #[props(optional)]
    filesize: Option<u32>,

    // The type of the file (e.g. "PDF", "JPEG")
    #[props(optional)]
    kind: Option<String>,

    // Whether the file is coming from a remote user, or we sent it.
    #[props(optional)]
    remote: Option<bool>,

    // The icon to use to represent the file
    #[props(optional)]
    icon: Option<Icon>,
}

pub fn get_icon(cx: &Scope<Props>) -> Icon {
    // If the props include an icon, return it
    // Otherwise, return a default icon (a question mark inside a circle)
    cx.props.icon.unwrap_or(Icon::QuestionMarkCircle)
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
