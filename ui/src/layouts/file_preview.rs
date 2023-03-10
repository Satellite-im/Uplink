use std::io::Cursor;

use common::{
    language::get_local_text, state::State, DOC_EXTENSIONS, IMAGE_EXTENSIONS, STATIC_ARGS,
    VIDEO_FILE_EXTENSIONS,
};
use dioxus::prelude::*;
use regex::Regex;
use warp::constellation::file::File;

use super::storage::WindowDropHandler;
use dioxus_desktop::{use_window, DesktopContext, LogicalSize};
use image::io::Reader as ImageReader;
use kit::elements::file::get_file_extension;
use notify::{Config, RecommendedWatcher, RecursiveMode, Watcher};
use std::sync::mpsc::channel;

const CSS_STYLE: &str = "
html, body {
    background: $BACKGROUND_COLOR;
}

.thumbnail-text {
    position: absolute;
    top: 0;
    left: 12px;
    background: $THUMB_BACKGROUND_COLOR;
    border-radius: 3px;
    padding: 1px;
}

.thumb-text {
    color: $THUMB_TEXT_COLOR;
}
";

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
    let file_format = get_file_format(file.name());
    let file_name = file.name();
    let thumbnail = file.thumbnail();
    let has_thumbnail = !file.thumbnail().is_empty();
    let desktop = use_window(cx);
    let mut css_style = update_theme_colors(CSS_STYLE.to_string());
    let update_state: &UseRef<Option<()>> = use_ref(cx, || Some(()));

    if update_state.read().is_some().clone() {
        css_style = update_theme_colors(css_style.clone());
        *update_state.write_silent() = None;
    }

    let first_render = use_state(cx, || true);

    resize_window(
        has_thumbnail,
        *first_render.get(),
        desktop,
        &thumbnail,
        file.clone(),
        &file_format,
    );

    if *first_render.get() {
        first_render.set(false);
    }

    use_future(cx, (), |_| {
        to_owned![update_state];
        async move {
            let (tx, rx) = channel();
            let fs_event_watcher_result = RecommendedWatcher::new(tx, Config::default());
            if let Ok(fs_event_watcher) = fs_event_watcher_result {
                let mut watcher: RecommendedWatcher = fs_event_watcher;
                if let Ok(_) = watcher.watch(
                    STATIC_ARGS.cache_path.clone().as_path(),
                    RecursiveMode::NonRecursive,
                ) {
                    loop {
                        let mut event_processed = false;
                        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
                        while let Ok(_) = rx.try_recv() {
                            if update_state.read().is_none() && !event_processed {
                                update_state.with_mut(|i| *i = Some(()));
                                event_processed = true;
                            }
                        }
                    }
                };
            }
        }
    });

    cx.render(rsx! (
        style { css_style },
        div {
            id: "video-poped-out",
            class: "file-preview",
            div {
                class: "wrap",
                {
                if file_format != FileFormat::Other && has_thumbnail {
                    rsx!{
                        div {
                            img {
                                src: "{thumbnail}",
                                width: "100%",
                        },
                            p {
                                class: "thumbnail-text thumb-text",
                                format!("{}", match file_format {
                                    FileFormat::Video => get_local_text("files.video-thumb"),
                                    FileFormat::Image => get_local_text("files.image-thumb"),
                                    FileFormat::Document => get_local_text("files.doc-thumb"),
                                    _ => String::from("Thumb"),
                                }),
                            }
                        }
                        }
                    } else {
                        rsx!(div{
                            h3 {
                                class: "thumb-text",
                                " {file_name}"}
                            p {
                                class: "thumb-text",
                                get_local_text("files.no-thumbnail-preview")}

                        })
                    }
                }
            },
        },
    ))
}

fn resize_window(
    has_thumbnail: bool,
    first_render: bool,
    desktop: &DesktopContext,
    thumbnail: &str,
    file: File,
    file_format: &FileFormat,
) -> Option<()> {
    if has_thumbnail && first_render {
        let base64_string = &thumbnail[thumbnail.find(',')? + 1..];
        let thumbnail_bytes = base64::decode(base64_string).ok()?;
        let cursor = Cursor::new(thumbnail_bytes);
        let img_format = if file.name().contains(".png") {
            image::ImageFormat::Png
        } else {
            image::ImageFormat::Jpeg
        };
        let image_reader = ImageReader::with_format(cursor, img_format);
        if let Ok(image) = image_reader.decode() {
            let (mut width, mut height) = (image.width() as f64, image.height() as f64);
            if height > 800.0 || width > 800.0 {
                let scale_factor = desktop.scale_factor() + 0.5;
                width /= scale_factor;
                height /= scale_factor;
            }
            desktop.set_inner_size(LogicalSize::new(width, height));
        }
    } else if first_render && file_format != &FileFormat::Other {
        let scale_factor = desktop.scale_factor() + 0.5;
        desktop.set_inner_size(LogicalSize::new(600.0 / scale_factor, 300.0 / scale_factor));
    }
    Some(())
}

fn update_theme_colors(mut css_style: String) -> String {
    let patterns = [
        (
            r"--background:\s*(?P<color>[^;]+)",
            "$BACKGROUND_COLOR",
            "#000000",
        ),
        (
            r"--primary:\s*(?P<color>[^;]+)",
            "$THUMB_BACKGROUND_COLOR",
            "#4D4DFF",
        ),
        (
            r"--text-color:\s*(?P<color>[^;]+)",
            "$THUMB_TEXT_COLOR",
            "rgb(247, 247, 253)",
        ),
    ];

    let state = State::load();
    let theme_str = format!("{:?}", state.ui.theme);

    for &(pattern, var_name, default_val) in &patterns {
        let re = Regex::new(pattern).unwrap();
        let color = re
            .captures(theme_str.as_str())
            .and_then(|captures| captures.name("color"))
            .map(|m| m.as_str())
            .unwrap_or(default_val);
        css_style = css_style.replace(var_name, color);
    }

    css_style
}
