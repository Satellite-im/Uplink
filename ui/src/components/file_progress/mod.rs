use common::icons::outline::Shape as Icon;
use common::state::data_transfer::{TransferProgress, TransferTracker};
use common::state::State;
use common::{language::get_local_text, state::data_transfer::FileProgress};
use dioxus::prelude::*;
use kit::elements::{button::Button, Appearance};

#[derive(Props)]
pub struct Props<'a> {
    state: &'a UseSharedState<State>,
    on_upload_pause: Option<EventHandler<'a, String>>,
    on_upload_cancel: Option<EventHandler<'a, String>>,
    on_download_pause: EventHandler<'a, String>,
    on_download_cancel: EventHandler<'a, String>,
    modal: Option<bool>,
}

pub fn FileTransferModal<'a>(cx: Scope<'a, Props>) -> Element<'a> {
    let file_tracker = use_shared_state::<TransferTracker>(cx)?;
    cx.props.state.write_silent().scope_ids.file_transfer = Some(cx.scope_id().0);
    let (file_progress_upload, file_progress_download) = (
        file_tracker.read().get_tracker(true),
        file_tracker.read().get_tracker(false),
    );
    if file_progress_upload.is_empty() && file_progress_download.is_empty() {
        return cx.render(rsx!(()));
    }
    let modal = cx.props.modal.unwrap_or_default();
    cx.render(rsx!(div {
        class: format_args!("file-transfer-wrap {}", if modal {"file-transfer-modal"} else {""}),
        (!file_progress_upload.is_empty()).then(||
            rsx!(FileTransferElement {
                transfers: file_progress_upload,
                label: get_local_text("uplink.upload-queue"),
                on_pause: move |f| {
                    if let Some(e) = cx.props.on_upload_pause.as_ref() {
                        e.call(f)
                    }
                },
                on_cancel: move |f| {
                    if let Some(e) = cx.props.on_upload_cancel.as_ref() {
                        e.call(f)
                    }
                }
            })
        ),
        (!file_progress_download.is_empty()).then(||
            rsx!(FileTransferElement {
                transfers: file_progress_download,
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
    transfers: Vec<FileProgress>,
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
                _ => 0
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
                            disabled: matches!(f.progress, TransferProgress::Paused | TransferProgress::Progress(100)),
                            appearance: Appearance::Primary,
                            small: true,
                            icon: Icon::Pause,
                            onpress: move |_| {
                                cx.props.on_pause.call(f.file.to_string());
                            },
                        },
                        Button {
                            aria_label: "cancel-upload".into(),
                            disabled: matches!(f.progress, TransferProgress::Cancelling | TransferProgress::Progress(100)),
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
