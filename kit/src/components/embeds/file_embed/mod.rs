use std::ffi::OsStr;
use std::path::PathBuf;

use crate::elements::button::Button;
use crate::elements::Appearance;
use crate::layout::modal::Modal;
use common::icons::outline::Shape as Icon;
use common::icons::Icon as IconElement;

use dioxus::prelude::*;

use humansize::format_size;
use humansize::DECIMAL;
use mime::IMAGE_JPEG;
use mime::IMAGE_PNG;
use mime::IMAGE_SVG;
use warp::constellation::Progression;

#[derive(Props)]
pub struct Props<'a> {
    // The filename of the file
    filename: String,

    // The local filepath of the file
    filepath: Option<PathBuf>,

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

    // The thumbnail for the file. If existent
    thumbnail: Option<String>,

    big: Option<bool>,

    // used to show download button, if nothing is passed, button will render
    with_download_button: Option<bool>,

    download_pending: Option<bool>,

    // called shen the icon is clicked
    on_press: EventHandler<'a, ()>,

    progress: Option<&'a Progression>,
}

#[allow(non_snake_case)]
pub fn FileEmbed<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let fullscreen_preview = use_state(cx, || false);
    let file_extension = std::path::Path::new(&cx.props.filename)
        .extension()
        .and_then(OsStr::to_str)
        .map(|s| format!(".{s}"))
        .unwrap_or_default();
    let file_extension_is_empty = file_extension.is_empty();
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

    let is_pending = cx.props.progress.is_some();

    let mut file_size_pending = String::new();

    let perc = if let Some(p) = cx.props.progress {
        match p {
            Progression::CurrentProgress {
                name: _,
                current,
                total,
            } => match total {
                Some(size) => {
                    file_size_pending
                        .push_str(&format_args!("{}", format_size(*size, DECIMAL)).to_string());
                    if *current > 0 && *size > 0 {
                        current * 100 / size
                    } else {
                        0
                    }
                }
                None => 0,
            },
            Progression::ProgressComplete { name: _, total } => {
                if let Some(size) = total {
                    file_size_pending
                        .push_str(&format_args!("{}", format_size(*size, DECIMAL)).to_string());
                };
                100
            }
            Progression::ProgressFailed {
                name: _,
                last_size: _,
                error: _,
            } => {
                file_size_pending.push_str("Failed");
                0
            }
        }
    } else {
        0
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
        None => {
            if file_size_pending.is_empty() {
                cx.props.kind.clone().unwrap_or_default()
            } else {
                file_size_pending
            }
        }
    };
    let remote = cx.props.remote.unwrap_or_default();
    let thumbnail = cx.props.thumbnail.clone().unwrap_or_default();
    let large_thumbnail = thumbnail.clone(); // TODO: This should be the source of the image
    let has_thumbnail = !thumbnail.is_empty();

    cx.render(rsx! (
        div {
            class: {
                format_args!(
                    "file-embed {} {}",
                    if remote {
                        "remote"
                    } else { "" },
                    if cx.props.big.unwrap_or_default() {
                        "big"
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
            if has_thumbnail {
                rsx!(
                    fullscreen_preview.then(|| rsx!(
                        Modal {
                            open: *fullscreen_preview.clone(),
                            onclose: move |_| fullscreen_preview.set(false),
                            transparent: false,
                            dont_pad: true,
                            img {
                                id: "image-preview-modal-file-embed",
                                aria_label: "image-preview-modal-file-embed",
                                src: "{large_thumbnail}",
                                max_height: "80vh",
                                max_width: "80vw",
                                onclick: move |e| e.stop_propagation(),
                            },
                        }
                    )),
                    div {
                        class: "image-container",
                        aria_label: "message-image-container",
                        img {
                            aria_label: "message-image",
                            onclick: move |_| fullscreen_preview.set(true),
                            class: format_args!(
                                "image {} expandable-image",
                                if cx.props.big.unwrap_or_default() {
                                    "big"
                                } else { "" }
                            ),
                            src: "{thumbnail}",
                        }
                        if with_download_button {
                            rsx!(Button {
                                        icon: btn_icon,
                                        appearance: Appearance::Primary,
                                        aria_label: "attachment-button".into(),
                                        onpress: move |_| cx.props.on_press.call(()),
                            }
                            )
                        }
                        if is_pending {
                            rsx!(div {
                                class: "upload-bar",
                                div {
                                    class: "upload-progress",
                                    style: format_args!("width: {}%", perc)
                                }
                            })
                        }
                    }
                )
            } else {
                rsx!(
                    div {
                        class: "icon",
                        aria_label: "file-icon",
                        if let Some(filepath) = cx.props.filepath.clone() {
                            let thubmnail = get_file_thumbnail_if_is_image(filepath, filename.clone());
                            if thubmnail.is_empty() {
                                rsx!(
                                    div {
                                        height: "60px",
                                        width: "60px",
                                        margin: "30px 0",
                                        IconElement {
                                            icon: cx.props.attachment_icon.unwrap_or(Icon::Document)
                                        }
                                        if !file_extension_is_empty {
                                            rsx!( label {
                                                class: "file-embed-type",
                                                "{file_extension}"
                                            })
                                        }
                                    }
                                    )
                            } else {
                                rsx!(img {
                                    aria_label: "image-preview-modal",
                                    src: "{thubmnail}",
                                    onclick: move |e| e.stop_propagation(),
                                })
                            }
                        } else {
                            rsx!(
                                div {
                                    height: "60px",
                                    IconElement {
                                        icon: cx.props.attachment_icon.unwrap_or(Icon::Document)
                                    }
                                    if !file_extension_is_empty {
                                        rsx!( label {
                                            class: "file-embed-type",
                                            "{file_extension}"
                                        })
                                    }
                                }
                                )
                        }
                    }
                    div {
                        class: "file-info",
                        width: "100%",
                        aria_label: "file-info",
                        p {
                            class: "name",
                            aria_label: "file-name",
                            color: "var(--text-color)",
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
                            div {
                                id: "file-embed-action-button", 
                                Button {
                                    icon: btn_icon,
                                    appearance: Appearance::Primary,
                                    aria_label: "attachment-button".into(),
                                    onpress: move |_| cx.props.on_press.call(()),
                                }
                            }
                        )
                    }
                    if is_pending {
                        rsx!(div {
                            class: "upload-bar",
                            div {
                                class: "upload-progress",
                                style: format_args!("width: {}%", perc)
                            }
                        })
                    }
                )
            }

        }
    ))
}

fn get_file_thumbnail_if_is_image(filepath: PathBuf, filename: String) -> String {
    let file = match std::fs::read(filepath) {
        Ok(file) => file,
        Err(_) => {
            return String::new();
        }
    };

    let parts_of_filename: Vec<&str> = filename.split('.').collect();
    let mime = match parts_of_filename.last() {
        Some(m) => match *m {
            "png" => IMAGE_PNG.to_string(),
            "jpg" => IMAGE_JPEG.to_string(),
            "jpeg" => IMAGE_JPEG.to_string(),
            "svg" => IMAGE_SVG.to_string(),
            &_ => "".to_string(),
        },
        None => "".to_string(),
    };

    if mime.is_empty() {
        return String::new();
    }

    let image = match &file.len() {
        0 => "".to_string(),
        _ => {
            let prefix = format!("data:{mime};base64,");
            let base64_image = base64::encode(&file);
            let img = prefix + base64_image.as_str();
            img
        }
    };
    image
}
