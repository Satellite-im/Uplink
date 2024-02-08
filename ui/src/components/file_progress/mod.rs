use common::icons::outline::Shape as Icon;
use common::state::data_transfer::TransferProgress;
use common::{language::get_local_text, state::data_transfer::FileProgress};
use dioxus::prelude::*;
use kit::elements::{button::Button, Appearance};

#[derive(Props)]
pub struct Props<'a> {
    file_progress_upload: Option<Vec<FileProgress>>,
    on_upload_pause: Option<EventHandler<'a, String>>,
    on_upload_cancel: Option<EventHandler<'a, String>>,
    file_progress_download: Vec<FileProgress>,
    on_download_pause: EventHandler<'a, String>,
    on_download_cancel: EventHandler<'a, String>,
}

pub fn FileTransferModal<'a>(cx: Scope<'a, Props>) -> Element<'a> {
    cx.render(rsx!(div {
        class: "file-transfer-modal",
        cx.props.file_progress_upload.as_ref().map(|uploads| (!uploads.is_empty()).then(||
            rsx!(FileTransferElement {
                transfers: uploads,
                label: get_local_text("uplink.upload-queue"),
                on_pause: move |f| {
                    if let Some(e) = cx.props.on_upload_cancel.as_ref() {
                        e.call(f)
                    }
                },
                on_cancel: move |f| {
                    if let Some(e) = cx.props.on_upload_pause.as_ref() {
                        e.call(f)
                    }
                }
            })
        )),
        (!cx.props.file_progress_download.is_empty()).then(||
            rsx!(FileTransferElement {
                transfers: &cx.props.file_progress_download,
                label: get_local_text("uplink.download-queue"),
                on_pause: move |f| {
                    cx.props.on_download_pause.call(f)
                },
                on_cancel: move |f| {
                    cx.props.on_download_cancel.call(f)
                }
            })
        ),
    }))
}

#[derive(Props)]
pub struct TransferProps<'a> {
    transfers: &'a Vec<FileProgress>,
    label: String,
    on_pause: EventHandler<'a, String>,
    on_cancel: EventHandler<'a, String>,
}

pub fn FileTransferElement<'a>(cx: Scope<'a, TransferProps<'a>>) -> Element<'a> {
    cx.render(rsx!(div {
        class: "file-transfer-container",
        div {
            class: "file-transfer-label-container",
            label {
                cx.props.label.clone(),
            },
        },
        cx.props.transfers.iter().map(|f| {
            let progress = match f.progress {
                TransferProgress::Progress(p) => p,
                _ => 0 as u8
            };
            rsx!(
                div {
                    class: "file-transfer-file",
                    div {
                        class: "file-icon-container",
                    }
                    div {
                        class: "progress-container",
                        div {
                            class: "progress-bar-filename-container",
                            p {
                                class: "filename-and-file-queue-text",
                                aria_label: "filename-and-file-queue-text",
                                margin_right: "auto",
                                f.file.to_string(),
                            },
                            p {
                                class: "transfer-progress-percentage",
                                aria_label: "transfer-progress-percentage",
                                format!("{}%", progress)
                            },
                        },
                        ProgressIndicator {
                            progress: progress
                        },
                    },
                    div {
                        class: "file-transfer-buttons",
                        Button {
                            aria_label: "pause-upload".into(),
                            appearance: Appearance::Primary,
                            small: true,
                            icon: Icon::Pause,
                            onpress: move |_| {
                                cx.props.on_pause.call(f.file.to_string());
                            },
                        },
                        Button {
                            aria_label: "cancel-upload".into(),
                            appearance: Appearance::Primary,
                            icon: Icon::XMark,
                            small: true,
                            onpress: move |_| {
                                cx.props.on_cancel.call(f.file.to_string());
                            },
                        }
                    }
                }
            )
        })
    }))
}

#[derive(Props, PartialEq)]
pub struct ProgressIndicatorProps {
    progress: u8,
}

pub fn ProgressIndicator(cx: Scope<ProgressIndicatorProps>) -> Element {
    cx.render(rsx!(div{
        class: "progress-indicator-wrap",
        div {
            class: "progress-indicator",
            div {
                class: "progress-indicator progress-indicator-overlay",
                width: format_args!("{}%", cx.props.progress)
            },
        }
    }))
}
