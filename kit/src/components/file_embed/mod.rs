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
    filesize: usize,

    // The type of the file (e.g. "PDF", "JPEG")
    kind: Option<String>,

    // Whether the file is coming from a remote user, or we sent it.
    remote: Option<bool>,

    // The icon to use to represent the file
    icon: Option<Icon>,

    // called shen the icon is clicked
    on_press: EventHandler<'a, ()>,
}

pub fn get_icon(cx: &Scope<Props>) -> Icon {
    // If the props include an icon, return it
    // Otherwise, return a default icon (a question mark inside a circle)
    cx.props.icon.unwrap_or(Icon::QuestionMarkCircle)
}

#[allow(non_snake_case)]
pub fn FileEmbed<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let filename = &cx.props.filename;
    // if kind is omitted, don't want the file size to appear negative
    let kind = format!("{} -", cx.props.kind.clone().unwrap_or_default());
    let filesize = cx.props.filesize;
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
                    "{kind} {filesize_str}"
                }
            },
            Button {
                icon: Icon::ArrowDown,
                appearance: Appearance::Primary,
                onpress: move |_| cx.props.on_press.call(()),
            }
        }
    ))
}
