use common::icons::outline::Shape as Icon;
use common::icons::Icon as IconElement;
use common::return_correct_icon;
use common::state::data_transfer::{TrackerType, TransferProgress, TransferTracker};
use common::state::State;
use common::{language::get_local_text, state::data_transfer::FileProgress};
use dioxus::prelude::*;
use futures::StreamExt;
use kit::elements::{button::Button, Appearance};

#[derive(Props)]
pub struct Props<'a> {
    state: &'a UseSharedState<State>,
    modal: Option<bool>,
}

pub fn FileTransferModal<'a>(cx: Scope<'a, Props>) -> Element<'a> {
    let file_tracker = use_shared_state::<TransferTracker>(cx)?;
    cx.props.state.write_silent().scope_ids.file_transfer = Some(cx.scope_id().0);
    let tracker = file_tracker.read();
    let (file_progress_upload, file_progress_download) = (
        tracker.get_tracker(TrackerType::FileUpload),
        tracker.get_tracker(TrackerType::FileDownload),
    );
    if file_progress_upload.is_empty() && file_progress_download.is_empty() {
        return cx.render(rsx!(()));
    }
    let modal = cx.props.modal.unwrap_or_default();
    cx.render(rsx!(div {
        class: format_args!("file-transfer-wrap {}", if modal {"file-transfer-modal"} else {""}),
        (!file_progress_upload.is_empty()).then(||
            rsx!(FileTransferElement {
                transfers: file_progress_upload.clone(),
                label: get_local_text("uplink.upload-queue"),
            })
        ),
        (!file_progress_download.is_empty()).then(||
            rsx!(FileTransferElement {
                transfers: file_progress_download.clone(),
                label: get_local_text("uplink.download-queue"),
            })
        ),
    }))
}

#[derive(Props, PartialEq)]
pub struct TransferProps {
    transfers: Vec<FileProgress>,
    label: String,
}

pub fn FileTransferElement(cx: Scope<TransferProps>) -> Element {
    cx.render(rsx!(div {
        class: "file-transfer-container",
        aria_label: "file-transfer-container",
        div {
            class: "file-transfer-label-container",
            aria_label: "file-transfer-label-container",
            label {
                aria_label: "file-transfer-label",
                cx.props.label.clone(),
            },
        },
        cx.props.transfers.iter().map(|f| {
            let progress = f.progress.get_progress();
            let state = f.state.clone();
            let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<bool>| {
                to_owned![state];
                async move {
                    while let Some(cancel) = rx.next().await {
                        state.update(cancel).await;
                    }
                }
            });
            rsx!(
                div {
                    class: "file-transfer-file",
                    aria_label: "file-transfer-file",
                    div {
                        class: "file-icon-container",
                        aria_label: "file-icon-container",
                        div {
                            IconElement {
                                icon: return_correct_icon(&f.file)
                            }
                        }
                    }
                    div {
                        class: "progress-container",
                        aria_label: "progress-container",
                        div {
                            class: "progress-bar-filename-container",
                            aria_label: "progress-bar-filename-container",
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
                        f.description.as_ref().map(|desc|rsx!(div {
                            class: "file-progress-description",
                            aria_label: "file-progress-description",
                            format!("{}", desc)
                        })),
                    },
                    div {
                        class: "file-transfer-buttons",
                        Button {
                            aria_label: "pause-upload".into(),
                            disabled: matches!(f.progress, TransferProgress::Progress(100)),
                            appearance: Appearance::Primary,
                            small: true,
                            icon: if matches!(f.progress, TransferProgress::Paused(_)) { Icon::Play } else { Icon::Pause },
                            onpress: move |_| {
                                ch.send(false);
                            },
                        },
                        Button {
                            aria_label: "cancel-upload".into(),
                            disabled: matches!(f.progress, TransferProgress::Cancelling(_) | TransferProgress::Progress(100)),
                            appearance: Appearance::Primary,
                            icon: Icon::XMark,
                            small: true,
                            onpress: move |_| {
                                ch.send(true);
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
