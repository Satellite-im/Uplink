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

    // used to show download button, if nothing is passed, button will render
    with_download_button: Option<bool>,

    download_pending: Option<bool>,

    // called shen the icon is clicked
    on_press: EventHandler<'a, ()>,
}

#[allow(non_snake_case)]
pub fn FileEmbed<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let filename = &cx.props.filename;
    let download_pending = cx.props.download_pending.unwrap_or(false);
    let btn_icon = if !download_pending {
        cx.props.button_icon.unwrap_or(Icon::ArrowDown)
    } else {
        Icon::DocumentArrowDown
    };

    let with_download_button = if let Some(with_download_button) = cx.props.with_download_button {
        with_download_button
    } else {
        true
    };

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
            if with_download_button {
                rsx!(
                    Button {
                        icon: btn_icon,
                        disabled: download_pending,
                        appearance: Appearance::Primary,
                        aria_label: "attachment-button".into(),
                        onpress: move |_| cx.props.on_press.call(()),
                    }
                )
            }

        }
    ))
}
