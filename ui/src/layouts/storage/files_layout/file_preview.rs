use std::path::PathBuf;

use dioxus::prelude::*;

use kit::{
    components::context_menu::{ContextItem, ContextMenu},
    layout::modal::Modal,
};
use warp::constellation::file::File;

use common::{
    icons::outline::Shape as Icon,
    is_video,
    language::get_local_text,
    state::State,
    utils::{
        img_dimensions_preview::{IMAGE_MAX_HEIGHT, IMAGE_MAX_WIDTH},
        local_file_path::get_fixed_path_to_load_local_file,
    },
    warp_runner::thumbnail_to_base64,
    STATIC_ARGS,
};

#[component(no_case_check)]
pub fn open_file_preview_modal<'a>(
    cx: Scope<'a>,
    on_dismiss: EventHandler<'a, ()>,
    on_download: EventHandler<'a, Option<PathBuf>>,
    file: File,
) -> Element<'a> {
    cx.render(rsx!(Modal {
        onclose: move |_| on_dismiss.call(()),
        open: true,
        transparent: false,
        dont_pad: true,
        close_on_click_inside_modal: true,
        children: cx.render(rsx!(FilePreview {
            file: file,
            on_download: |temp_path| {
                on_download.call(temp_path);
            },
        }))
    }))
}

#[derive(Props)]
struct Props<'a> {
    file: &'a File,
    on_download: EventHandler<'a, Option<PathBuf>>,
}

#[allow(non_snake_case)]
fn FilePreview<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let state = use_shared_state::<State>(cx)?;
    let file_path_in_local_disk = use_ref(cx, || PathBuf::new());

    let thumbnail = thumbnail_to_base64(cx.props.file);
    let temp_dir = STATIC_ARGS.temp_files.join(cx.props.file.name());
    let temp_dir_with_file_id = STATIC_ARGS.temp_files.join(format!(
        "{}.{}",
        cx.props.file.id().to_string(),
        temp_dir.extension().unwrap_or_default().to_string_lossy()
    ));

    let is_video = is_video(&cx.props.file.name());
    if file_path_in_local_disk.read().to_string_lossy().is_empty() {
        if !temp_dir_with_file_id.exists() {
            cx.props.on_download.call(Some(temp_dir.clone()));
        }
        if temp_dir_with_file_id.exists() {
            file_path_in_local_disk.set(temp_dir_with_file_id.clone());
        }
    }

    use_future(cx, (), |_| {
        to_owned![temp_dir, file_path_in_local_disk, temp_dir_with_file_id];
        async move {
            loop {
                if file_path_in_local_disk.read().exists() {
                    break;
                }
                if temp_dir.exists() {
                    let _ = tokio::fs::rename(
                        temp_dir.to_string_lossy().to_string(),
                        temp_dir_with_file_id.to_string_lossy().to_string(),
                    )
                    .await;
                    file_path_in_local_disk.set(temp_dir_with_file_id);
                    break;
                }
                tokio::time::sleep(tokio::time::Duration::from_millis(250)).await;
            }
        }
    });

    let fixed_path = get_fixed_path_to_load_local_file(file_path_in_local_disk.read().clone());

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
            if is_video {
                rsx!(video {
                    id: "file_preview_img",
                    aria_label: "file-preview-image",
                    max_height: IMAGE_MAX_HEIGHT,
                    max_width: IMAGE_MAX_WIDTH,
                    autoplay: true,
                    controls: true,
                    src: format_args!("{}", if file_path_in_local_disk.read().exists()
                        { fixed_path }
                        else {"".to_string()} ),
                })
            } else {
                rsx!(img {
                    id: "file_preview_img",
                    aria_label: "file-preview-image",
                    max_height: IMAGE_MAX_HEIGHT,
                    max_width: IMAGE_MAX_WIDTH,
                    src: format_args!("{}", if file_path_in_local_disk.read().exists()
                        { fixed_path }
                        else {thumbnail} ),
                },)
            }
        },
    ))
}
