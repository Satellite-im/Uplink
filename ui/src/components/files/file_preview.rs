use std::borrow::Cow;
use std::io::{BufWriter, Read, Write};

use common::language::get_local_text;
use common::{icons::outline::Shape as Icon, warp_runner::thumbnail_to_base64};
use dioxus::prelude::*;
use image::{DynamicImage, ImageBuffer, ImageOutputFormat, RgbaImage};
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
    let image_from_clipboard = use_ref(cx, || String::new());

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
                       let test =  copy_base64_image_to_clipboard(&thumbnail2).unwrap_or_default();
                       image_from_clipboard.with_mut(|i| *i = test);
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
            img {
                id: "file_preview_img",
                src: format_args!("{}", image_from_clipboard.read()),
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
use clipboard::{ClipboardContext, ClipboardProvider};
use std::process::Command;
use std::str;

fn copy_base64_image_to_clipboard(
    base64_image: &str,
) -> Result<String, Box<dyn std::error::Error>> {
    let mut clipboard = Clipboard::new().unwrap();
    let mut clipboard2: ClipboardContext = ClipboardProvider::new()?;
    let output = Command::new("osascript")
        .arg("-e")
        .arg("get the clipboard as «class furl»")
        .output()?;
    let file_path = str::from_utf8(&output.stdout)?
        .trim()
        .to_owned()
        .replace("file Macintosh HD:", "")
        .replace(":", "/");

    println!("file_path: {:?}", file_path);

    let mut file = std::fs::File::open(file_path)?;
    let mut content = Vec::new();
    file.read_to_end(&mut content)?;
    let base64_default_image = format!("data:image/png;base64,{}", base64::encode(content));
    return Ok(base64_default_image);

    // let clipboard_content = clipboard2.get_contents()?;
    // println!("clipboard_content: {:?}", clipboard_content);

    // let image = match clipboard.get_image() {
    //     Ok(img) => img,
    //     Err(e) => {
    //         eprintln!("error getting image: {}", e);
    //         return Ok("".to_owned());
    //     }
    // };
    // eprintln!("getting {}×{} image", image.width, image.height);

    // // let image: RgbaImage = ImageBuffer::from_raw(
    // //     image.width.try_into().unwrap(),
    // //     image.height.try_into().unwrap(),
    // //     image.bytes.into_owned(),
    // // )
    // // .unwrap();
    // // let file_path = "/Users/lucasmarchi/Desktop/output.png";
    // // let image = DynamicImage::ImageRgba8(image);
    // // let file = std::fs::File::create(file_path)?;
    // // println!("Arriving here - 3");

    // // let mut buffered_writer = BufWriter::new(file);
    // // image
    // //     .write_to(&mut buffered_writer, ImageOutputFormat::Png)
    // //     .unwrap();
    // // println!("Arriving here - 4");
    // // let mut file = std::fs::File::open(file_path)?;
    // // let mut content = Vec::new();
    // // file.read_to_end(&mut content)?;
    // // let base64_default_image = format!("data:image/png;base64,{}", base64::encode(content));
    // // Ok(base64_default_image)
}
