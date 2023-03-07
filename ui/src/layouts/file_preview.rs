use common::{DOC_EXTENSIONS, IMAGE_EXTENSIONS};
use dioxus::prelude::*;

use common::icons::Icon as IconElement;
use common::{icons::outline::Shape as Icon, VIDEO_FILE_EXTENSIONS};
use kit::elements::file::get_file_extension;
use kit::elements::{
    button::Button,
    file::is_video,
    tooltip::{ArrowPosition, Tooltip},
    Appearance,
};
use warp::constellation::file::File;

use crate::{window_manager::WindowManagerCmd, WINDOW_CMD_CH};

use super::storage::WindowDropHandler;

#[derive(Clone, PartialEq, Eq)]
pub enum FileFormat {
    Video,
    Image,
    Document,
    Other,
}

pub fn get_file_format(file_name: String) -> FileFormat {
    let file_extension = get_file_extension(file_name);

    let image_formats = IMAGE_EXTENSIONS.to_vec();
    if image_formats.iter().any(|f| f == &file_extension) {
        return FileFormat::Image;
    }

    let video_formats = VIDEO_FILE_EXTENSIONS.to_vec();

    if video_formats.iter().any(|f| f == &file_extension) {
        return FileFormat::Video;
    }

    let doc_formats = DOC_EXTENSIONS.to_vec();

    if doc_formats.iter().any(|f| f == &file_extension) {
        return FileFormat::Document;
    }
    return FileFormat::Other;
}

#[inline_props]
#[allow(non_snake_case)]
pub fn FilePreview(cx: Scope, _drop_handler: WindowDropHandler, file: File) -> Element {
    // let cmd_tx = WINDOW_CMD_CH.tx.clone();
    let file_format = get_file_format(file.name());
    let thumbnail = file.thumbnail();

    cx.render(rsx! (
        div {
            id: "video-poped-out",
            class: "popout-player",
            div {
                class: "wrap",
                {
                if file_format == FileFormat::Image || file_format == FileFormat::Video {
                        rsx!(img {
                            src: "{thumbnail}",
                            width: "100%",
                        })
                    } else {
                        rsx!(div{})
                    }
                }
            },
        },
    ))
}
