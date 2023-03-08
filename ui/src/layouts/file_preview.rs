use std::io::Cursor;

use common::{DOC_EXTENSIONS, IMAGE_EXTENSIONS};
use dioxus::prelude::*;

use common::icons::Icon as IconElement;
use common::{icons::outline::Shape as Icon, VIDEO_FILE_EXTENSIONS};
use dioxus_desktop::{use_window, LogicalSize};
use image::io::Reader as ImageReader;
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
    let has_thumbnail = !file.thumbnail().is_empty();
    let desktop = use_window(cx);

    if has_thumbnail {
        let base64_string = &thumbnail[thumbnail.find(',')? + 1..];
        if let Ok(thumbnail_bytes) = base64::decode(base64_string) {
            let cursor = Cursor::new(thumbnail_bytes);
            let mut img_format = image::ImageFormat::Jpeg;
            if file.name().contains(".png") {
                img_format = image::ImageFormat::Png;
            }
            let image_reader = ImageReader::with_format(cursor, img_format);
            if let Ok(image) = image_reader.decode() {
                let width = image.width() as f64;
                let height = image.height() as f64;
                if height > 800.0 || width > 800.0 {
                    let scale_factor = desktop.scale_factor() + 0.5;
                    desktop.set_inner_size(LogicalSize::new(
                        width / scale_factor,
                        height / scale_factor,
                    ));
                } else {
                    desktop.set_inner_size(LogicalSize::new(width, height));
                }
            }
        }
    }

    cx.render(rsx! (
        div {
            id: "video-poped-out",
            class: "popout-player",
            div {
                class: "wrap",
                {
                if file_format != FileFormat::Other && has_thumbnail {
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
