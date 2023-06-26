use common::language::get_local_text;
use dioxus::prelude::*;
use dioxus_desktop::{use_window, DesktopContext};
use std::path::PathBuf;
use wry::webview::FileDropEvent;

use super::{
    functions::{decoded_pathbufs, get_drag_event, verify_if_there_are_valid_paths},
    ChanCmd,
};

#[derive(PartialEq, Props)]
pub struct Props<'a> {
    are_files_hovering_app: &'a UseRef<bool>,
}

#[allow(non_snake_case)]
pub fn UploadProgressBar<'a>(cx: Scope<'a, Props>) -> Element<'a> {
    let are_files_hovering_app = cx.props.are_files_hovering_app.clone();
    let files_to_upload_message = use_ref(cx, || {
        format!("{} {}!", 1, get_local_text("files.one-file-to-upload"))
    });
    let window = use_window(cx);

    if *cx.props.are_files_hovering_app.read() {
        cx.spawn({
            to_owned![are_files_hovering_app, window, files_to_upload_message];
            async move {
                drag_and_drop_function(&window, &are_files_hovering_app, &files_to_upload_message)
                    .await;
            }
        });
    } else {
        return cx.render(rsx!(div {}));
    }

    cx.render(rsx!(
        div {
            class: "upload-progress-bar",
            p {
                class: "upload-file-count",
                "{files_to_upload_message.read()}"
            }
        },
    ))
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
    files_to_upload_message: &UseRef<String>,
) {
    *are_files_hovering_app.write_silent() = true;
    loop {
        let file_drop_event = get_drag_event();
        match file_drop_event {
            FileDropEvent::Hovered { paths, .. } => {
                if verify_if_there_are_valid_paths(&paths) {
                    *files_to_upload_message.write_silent() =
                        get_files_to_upload_message(paths.len());
                    // window.eval(&script);
                }
            }
            FileDropEvent::Dropped { paths, .. } => {
                if verify_if_there_are_valid_paths(&paths) {
                    let new_files_to_upload = decoded_pathbufs(paths);
                    // TODO: Return action to upload files
                    break;
                }
            }
            _ => {
                // let script = main_script.replace("$IS_DRAGGING", "false");
                // window.eval(&script);
                break;
            }
        };
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    *are_files_hovering_app.write_silent() = false;
}
