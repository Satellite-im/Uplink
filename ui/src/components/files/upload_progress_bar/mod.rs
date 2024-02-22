use std::path::PathBuf;

use common::language::{get_local_text, get_local_text_with_args};
use dioxus::prelude::*;
use dioxus_desktop::wry::webview::FileDropEvent;
use dioxus_desktop::{use_window, DesktopContext};
use kit::elements::{button::Button, Appearance};

use crate::utils::get_drag_event::BLOCK_CANCEL_DRAG_EVENT_FOR_LINUX;
use crate::utils::{
    get_drag_event,
    verify_valid_paths::{decoded_pathbufs, verify_paths},
};

static FILES_TO_UPLOAD_SCRIPT: &str = r#"
    var element = document.getElementById('upload-file-count');
    element.textContent = '$TEXT';
"#;

static PROGRESS_UPLOAD_PERCENTAGE_SCRIPT: &str = r#"
    var element = document.getElementById('upload-progress-percentage');
    element.textContent = '$TEXT';

    var element_percentage = document.getElementById('progress-percentage');
    element_percentage.style.width = '$WIDTH';
"#;

static PROGRESS_UPLOAD_DESCRIPTION_SCRIPT: &str = r#"
    var element = document.getElementById('upload-progress-description');
    element.textContent = '$TEXT';
"#;

static UPDATE_FILENAME_SCRIPT: &str = r#"
    var element = document.getElementById('upload-progress-filename');
    element.textContent = '$TEXT';
"#;

static UPDATE_FILE_QUEUE_SCRIPT: &str = r#"
    var element = document.getElementById('upload-progress-files-queue');
    element.textContent = '$TEXT_TRANSLATED ($FILES_IN_QUEUE)';
"#;

static UPDATE_FILES_TO_DROP: &str = r#"
    var element = document.getElementById('upload-progress-drop-files');
    element.textContent = '$TEXT1 $FILES_NUMBER $TEXT2';
"#;

pub fn change_progress_percentage(window: &DesktopContext, new_percentage: String) {
    let new_script = PROGRESS_UPLOAD_PERCENTAGE_SCRIPT
        .replace("$TEXT", &new_percentage)
        .replace("$WIDTH", &new_percentage);
    _ = window.webview.evaluate_script(&new_script);
}

pub fn change_progress_description(window: &DesktopContext, new_description: String) {
    let new_script = PROGRESS_UPLOAD_DESCRIPTION_SCRIPT.replace("$TEXT", &new_description);
    _ = window.webview.evaluate_script(&new_script);
}

pub fn update_filename(window: &DesktopContext, filename: String) {
    let new_script = UPDATE_FILENAME_SCRIPT.replace("$TEXT", &filename);
    _ = window.webview.evaluate_script(&new_script);
}

pub fn update_files_queue_len(window: &DesktopContext, files_in_queue: usize) {
    let new_script = UPDATE_FILE_QUEUE_SCRIPT
        .replace(
            "$TEXT_TRANSLATED",
            &format!(" / {}", get_local_text("files.files-in-queue")),
        )
        .replace("$FILES_IN_QUEUE", &format!("{}", files_in_queue));
    _ = window.webview.evaluate_script(&new_script);
}

fn update_files_to_drop_while_upload_other_file(
    window: &DesktopContext,
    files_to_drop: usize,
    hovering: bool,
) {
    let new_script = if hovering {
        UPDATE_FILES_TO_DROP
            .replace("$TEXT1", &format!(" / {}", get_local_text("uplink.add")))
            .replace("$FILES_NUMBER", &format!("{}", files_to_drop))
            .replace(
                "$TEXT2",
                &(if files_to_drop > 1 {
                    get_local_text("files.files")
                } else {
                    get_local_text("files.file")
                }),
            )
    } else {
        UPDATE_FILES_TO_DROP
            .replace("$TEXT1", "")
            .replace("$FILES_NUMBER", "")
            .replace("$TEXT2", "")
    };
    _ = window.webview.evaluate_script(&new_script);
}

#[derive(Props)]
pub struct Props<'a> {
    are_files_hovering_app: &'a UseRef<bool>,
    files_been_uploaded: &'a UseRef<bool>,
    disable_cancel_upload_button: &'a UseRef<bool>,
    on_update: EventHandler<Vec<PathBuf>>,
    on_cancel: EventHandler<()>,
}

#[allow(non_snake_case)]
pub fn UploadProgressBar<'a>(cx: Scope<'a, Props>) -> Element {
    let are_files_hovering_app = cx.props.are_files_hovering_app.clone();
    let files_ready_to_upload: &UseRef<Vec<PathBuf>> = use_ref(cx, Vec::new);
    let called_drag_and_drop_function: &UseRef<bool> = use_ref(cx, || false);
    let window = use_window(cx);

    if *cx.props.are_files_hovering_app.read() && !*called_drag_and_drop_function.read() {
        *called_drag_and_drop_function.write_silent() = true;
        cx.spawn({
            to_owned![
                are_files_hovering_app,
                window,
                files_ready_to_upload,
                called_drag_and_drop_function
            ];
            async move {
                drag_and_drop_function(
                    &window,
                    &are_files_hovering_app,
                    &files_ready_to_upload,
                    &called_drag_and_drop_function,
                )
                .await;
            }
        });
    }

    if files_ready_to_upload.with(|i| !i.is_empty()) {
        *cx.props.files_been_uploaded.write_silent() = true;
        cx.props
            .on_update
            .call(files_ready_to_upload.read().clone());
        *files_ready_to_upload.write_silent() = Vec::new();
    }

    if *cx.props.files_been_uploaded.read() {
        return cx.render(rsx!(
            div {
                class: "upload-progress-bar-container",
                aria_label: "upload-progress-bar-container",
                div {
                    class: "progress-percentage-description-container",
                    aria_label: "progress-percentage-description-container",
                    p {
                        id: "upload-progress-description",
                        class: "upload-progress-description",
                        aria_label: "upload-progress-description",
                        get_local_text("files.uploading-file"),
                    },
                    p {
                        id: "upload-progress-percentage",
                        class: "upload-progress-percentage",
                        aria_label: "upload-progress-percentage",
                        "0%",
                    },
                    p {
                        id: "upload-progress-drop-files",
                        class: "upload-progress-drop-files",
                        aria_label: "upload-progress-drop-files",
                    },
                },
                div {
                    class: "progress-bar-button-container",
                    aria_label: "progress-bar-button-container",
                    div {
                        class: "progress-bar-filename-container",
                        aria_label: "progress-bar-filename-container",
                        div {
                            class: "progress-bar",
                            aria_label: "progress-bar",
                            div {
                                id: "progress-percentage",
                                class: "progress-percentage",
                                aria_label: "progress-percentage",
                            },
                        }
                        div {
                            class: "filaname-and-queue-container",
                            aria_label: "filaname-and-queue-container",
                            p {
                                id: "upload-progress-filename",
                                class: "filename-and-file-queue-text",
                                aria_label: "filename-and-file-queue-text",
                            },
                            p {
                                id: "upload-progress-files-queue",
                                aria_label: "upload-progress-files-queue",
                                class: "file-queue-text",
                            },
                        }
                    }
                    div {
                        class: "cancel-button",
                        Button {
                            aria_label: "cancel-upload".into(),
                            disabled: *cx.props.disable_cancel_upload_button.read(),
                            appearance: Appearance::Primary,
                            onpress: move |_| {
                                cx.props.on_cancel.call(());
                            },
                            text: get_local_text("uplink.cancel"),
                        }
                    }
                }

            },
        ));
    }

    if !*cx.props.are_files_hovering_app.read() {
        return None;
    }

    cx.render(rsx!(
                div {
                    class: "upload-progress-bar-container-file-count",
                    aria_label: "upload-progress-bar-container-file-count",
                    p {
                        id: "upload-file-count",
                        class: "upload-file-count",
                        aria_label: "upload-file-count",
                    }
                },
    ))
}

fn count_files_to_show(files_to_upload_len: usize) -> String {
    if files_to_upload_len > 1 {
        get_local_text_with_args("files.files-to-upload", vec![("num", files_to_upload_len)])
    } else {
        get_local_text_with_args("files.one-file-to-upload", vec![("num", 1)])
    }
}

async fn drag_and_drop_function(
    window: &DesktopContext,
    are_files_hovering_app: &UseRef<bool>,
    files_ready_to_upload: &UseRef<Vec<PathBuf>>,
    called_drag_and_drop_function: &UseRef<bool>,
) {
    *are_files_hovering_app.write_silent() = true;
    loop {
        let file_drop_event = get_drag_event::get_drag_event();
        match file_drop_event {
            FileDropEvent::Hovered { paths, .. } => {
                if verify_paths(&paths) {
                    let files_to_upload_message = count_files_to_show(paths.len());
                    let new_script =
                        FILES_TO_UPLOAD_SCRIPT.replace("$TEXT", &files_to_upload_message);
                    _ = window.webview.evaluate_script(&new_script);
                    update_files_to_drop_while_upload_other_file(window, paths.len(), true);
                }
            }
            FileDropEvent::Dropped { paths, .. } => {
                if verify_paths(&paths) {
                    let new_files_to_upload = decoded_pathbufs(paths);
                    *files_ready_to_upload.write_silent() = new_files_to_upload;
                    if cfg!(target_os = "linux") {
                        *BLOCK_CANCEL_DRAG_EVENT_FOR_LINUX.write() = false;
                    }
                    break;
                }
            }
            _ => {
                break;
            }
        };
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    update_files_to_drop_while_upload_other_file(window, 0, false);
    *called_drag_and_drop_function.write_silent() = false;
    are_files_hovering_app.with_mut(|i| *i = false);
}
