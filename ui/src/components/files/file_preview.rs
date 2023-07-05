use std::borrow::Cow;

use common::language::get_local_text;
use common::{icons::outline::Shape as Icon, warp_runner::thumbnail_to_base64};
use dioxus::prelude::*;
use kit::components::context_menu::{ContextItem, ContextMenu};
use warp::constellation::file::File;

#[derive(Props)]
pub struct Props<'a> {
    file: &'a File,
    on_download: EventHandler<'a, ()>,
}

#[allow(non_snake_case)]
pub fn FilePreview<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let thumbnail = thumbnail_to_base64(cx.props.file);
    let thumbnail2 = thumbnail.clone();

    cx.render(rsx!(div {
        ContextMenu {
            id: "file-preview-context-menu".into(),
            items: cx.render(rsx!(
                ContextItem {
                    icon: Icon::ArrowDownCircle,
                    aria_label: "files-download-preview".into(),
                    text: get_local_text("files.download"),
                    onpress: move |_| {
                        cx.props.on_download.call(());
                    }
                },
                ContextItem {
                    icon: Icon::ArrowDownCircle,
                    aria_label: "files-download-preview".into(),
                    text: "Copy".to_owned(),
                    onpress: move |_| {
                        copy_base64_image_to_clipboard(&thumbnail2);
                    }
                },
            )),
            img {
                id: "file_preview_img",
                src: "{thumbnail}",
                position: "absolute",
                top: "50%",
                left: "50%",
                transform: "translate(-50%, -50%)",
                max_height: "80%",
                max_width: "80%",
            },
        },
    }))
}

use arboard::Clipboard;
use arboard::ImageData;

fn copy_base64_image_to_clipboard(base64_image: &str) -> Result<(), Box<dyn std::error::Error>> {
    let data_start_index = base64_image.find("base64,").unwrap_or(0) + 7;
    let base64_data = &base64_image[data_start_index..];
    println!("base64_image: {:?}", base64_data);

    // Convert the base64 image to bytes
    let decoded_image = base64::decode(base64_data)?;
    println!("Arriving here - 1");

    let cow_data: Cow<[u8]> = Cow::Owned(decoded_image);
    println!("Arriving here - 2");

    let image_data = ImageData {
        bytes: cow_data,
        width: 264,
        height: 264,
    };
    println!("Arriving here - 3");

    // Create a clipboard context
    let mut clipboard = Clipboard::new()?;
    println!("Arriving here - 4");

    // Copy the bytes to the clipboard
    clipboard.set_image(image_data)?;

    Ok(())
}
