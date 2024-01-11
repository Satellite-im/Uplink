use std::fs;
use std::path::PathBuf;

use common::language::get_local_text;
use common::state::State;
use common::utils::img_dimensions_preview::{IMAGE_MAX_HEIGHT, IMAGE_MAX_WIDTH};
use common::utils::lifecycle::use_component_lifecycle;
use common::STATIC_ARGS;
use common::{icons::outline::Shape as Icon, warp_runner::thumbnail_to_base64};
use dioxus::prelude::*;
use kit::components::context_menu::{ContextItem, ContextMenu};
use mime::{IMAGE_JPEG, IMAGE_PNG, IMAGE_SVG};
use warp::constellation::file::File;

#[derive(Props)]
pub struct Props<'a> {
    file: &'a File,
    on_download: EventHandler<'a, Option<PathBuf>>,
}

#[allow(non_snake_case)]
pub fn FilePreview<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let thumbnail = thumbnail_to_base64(cx.props.file);
    let state = use_shared_state::<State>(cx)?;
    let temp_dir = STATIC_ARGS.temp_files.join(cx.props.file.name());
    let temp_dir2 = temp_dir.clone();

    if !temp_dir.exists() {
        cx.props.on_download.call(Some(temp_dir.clone()));
    }
    let temp_file_path_as_string = if !cfg!(target_os = "windows") {
        temp_dir.to_string_lossy().to_string()
    } else {
        format!(
            "http://dioxus.{}",
            temp_dir.to_string_lossy().to_string().replace("\\", "/")
        )
    };

    use_component_lifecycle(
        cx,
        || {},
        move || {
            let _ = fs::remove_file(temp_dir2.clone());
        },
    );

    cx.render(rsx!(
        ContextMenu {
            id: "file-preview-context-menu".into(),
            devmode: state.read().configuration.developer.developer_mode,
            items: cx.render(rsx!(
                ContextItem {
                    icon: Icon::ArrowDownCircle,
                    aria_label: "files-download-preview".into(),
                    text: get_local_text("files.download"),
                    onpress: move |_| {
                        cx.props.on_download.call(None);
                    }
                },
            )),
            img {
                id: "file_preview_img",
                aria_label: "file-preview-image",
                max_height: IMAGE_MAX_HEIGHT,
                max_width: IMAGE_MAX_WIDTH,
                src: format_args!("{}", if temp_dir.exists()
                    { temp_file_path_as_string }
                    else {thumbnail} ),
            },
        },
    ))
}
