use std::path::PathBuf;

use common::language::get_local_text;
use dioxus::prelude::*;
use dioxus_desktop::{use_window, DesktopContext};
use wry::webview::FileDropEvent;

use super::functions::{decoded_pathbufs, get_drag_event, verify_if_there_are_valid_paths};

static FILES_TO_UPLOAD_SCRIPT: &str = r#"
    var element = document.getElementById('upload-file-count');
    element.textContent = '$TEXT';
"#;

#[derive(Props)]
pub struct Props<'a> {
    are_files_hovering_app: &'a UseRef<bool>,
    on_update: EventHandler<'a, Vec<PathBuf>>,
}

#[allow(non_snake_case)]
pub fn UploadProgressBar<'a>(cx: Scope<'a, Props>) -> Element<'a> {
    let are_files_hovering_app = cx.props.are_files_hovering_app.clone();
    let files_ready_to_upload: &UseRef<Vec<PathBuf>> = use_ref(cx, || Vec::new());
    let window = use_window(cx);

    if files_ready_to_upload.with(|i| !i.is_empty()) {
        cx.props
            .on_update
            .call(files_ready_to_upload.read().clone());
    }

    return cx.render(rsx!(
        div {
            class: "upload-progress-bar-container",
            p {
                id: "upload-progress-description",
                class: "upload-progress-description",
                "File is Uploading... 30%"
            },
            div {
                class: "progress-bar",
                div {
                    class: "progress-percentage",
                }
            }

        },
    ));

    // if *cx.props.are_files_hovering_app.read() {
    //     cx.spawn({
    //         to_owned![are_files_hovering_app, window, files_ready_to_upload];
    //         async move {
    //             drag_and_drop_function(&window, &are_files_hovering_app, &files_ready_to_upload)
    //                 .await;
    //         }
    //     });

    //     return cx.render(rsx!(
    //         div {
    //             class: "upload-progress-bar-container",
    //             p {
    //                 id: "upload-file-count",
    //                 class: "upload-file-count",
    //                 ""
    //             }
    //         },
    //     ));
    // } else {
    //     return cx.render(rsx!(div {}));
    // }
}

fn get_files_to_upload_message(files_to_upload_len: usize) -> String {
    if files_to_upload_len > 1 {
        format!(
            "{} {}!",
            files_to_upload_len,
            get_local_text("files.files-to-upload")
        )
    } else {
        format!("{} {}!", 1, get_local_text("files.one-file-to-upload"))
    }
}

pub async fn drag_and_drop_function(
    window: &DesktopContext,
    are_files_hovering_app: &UseRef<bool>,
    files_ready_to_upload: &UseRef<Vec<PathBuf>>,
) {
    *are_files_hovering_app.write_silent() = true;
    loop {
        let file_drop_event = get_drag_event();
        match file_drop_event {
            FileDropEvent::Hovered { paths, .. } => {
                if verify_if_there_are_valid_paths(&paths) {
                    let files_to_upload_message = get_files_to_upload_message(paths.len());
                    let new_script =
                        FILES_TO_UPLOAD_SCRIPT.replace("$TEXT", &files_to_upload_message);
                    window.eval(&new_script);
                }
            }
            FileDropEvent::Dropped { paths, .. } => {
                if verify_if_there_are_valid_paths(&paths) {
                    let new_files_to_upload = decoded_pathbufs(paths);
                    files_ready_to_upload.with_mut(|i| *i = new_files_to_upload);
                    break;
                }
            }
            _ => {
                break;
            }
        };
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    are_files_hovering_app.with_mut(|i| *i = false);
}
