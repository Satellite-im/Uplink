use crate::elements::button::Button;
use crate::elements::Appearance;
use common::icons::outline::Shape as Icon;
use common::icons::Icon as IconElement;

use dioxus::prelude::*;

use humansize::format_size;
use humansize::DECIMAL;

#[derive(Props)]
pub struct Props<'a> {
    // The filename of the file
    filename: String,

    // The size of the file in bytes
    filesize: Option<usize>,

    // The type of the file (e.g. "PDF", "JPEG")
    kind: Option<String>,

    // Whether the file is coming from a remote user, or we sent it.
    remote: Option<bool>,

    // The icon to use to represent the file
    attachment_icon: Option<Icon>,

    // used for the button. defaults to a download icon
    button_icon: Option<Icon>,

    // called shen the icon is clicked
    on_press: EventHandler<'a, ()>,
}

#[allow(non_snake_case)]
pub fn FileEmbed<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let filename = &cx.props.filename;

    // show one of the 3:
    // kind
    // kind - size
    // size
    let file_description = match cx.props.filesize {
        Some(filesize) => {
            let size = format_size(filesize, DECIMAL);
            match cx.props.kind.as_ref() {
                Some(kind) => format!("{kind} - {size}"),
                None => size,
            }
        }
        None => cx.props.kind.clone().unwrap_or_default(),
    };
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
            aria_label: {
                format_args!(
                    "file-embed{}",
                    if remote {
                        "-remote"
                    } else { "" }
                )
            },
            div {
                class: "icon",
                aria_label: "file-icon",
                IconElement {
                    icon: cx.props.attachment_icon.unwrap_or(Icon::QuestionMarkCircle)
                },
            }
            div {
                class: "file-info",
                aria_label: "file-info",
                p {
                    class: "name",
                    aria_label: "file-name",
                    "{filename}"
                },
                p {
                    class: "meta",
                    aria_label: "file-meta",
                    "{file_description}"
                }
            },
            Button {
                icon: cx.props.button_icon.unwrap_or(Icon::ArrowDown),
                appearance: Appearance::Primary,
                aria_label: "attachment-button".into(),
                onpress: move |_| cx.props.on_press.call(()),
            }
        }
    ))
}
