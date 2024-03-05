use common::{
    icons::outline::Shape as Icon,
    language::get_local_text_with_args,
    state::{
        data_transfer::{TransferState, TransferStates},
        pending_message::PendingMessage,
    },
    warp_runner::{ui_adapter::MessageEvent, WarpEvent},
    WARP_EVENT_CH,
};
use dioxus_core::ScopeState;
use dioxus_hooks::{use_ref, UseRef};
use futures::{Future, StreamExt};
use tokio::{
    sync::{
        mpsc::{UnboundedReceiver, UnboundedSender},
        Mutex,
    },
    time::sleep,
};

use once_cell::sync::Lazy;
use std::{sync::Arc, time::Duration};
use uuid::Uuid;
use warp::{
    constellation::Progression,
    raygun::{AttachmentEventStream, AttachmentKind, Location},
};

use super::download::DownloadComplete;

pub enum ListenerAction {
    ToastAction {
        title: String,
        content: String,
        icon: Option<Icon>,
        timeout: u32,
    },
    TransferProgress {
        id: Uuid,
        progression: Progression,
        download: bool,
    },
    PauseTransfer {
        id: Uuid,
        download: bool,
    },
    CancelTransfer {
        id: Uuid,
        download: bool,
    },
    FinishTransfer {
        id: Uuid,
        download: bool,
    },
}

pub struct ListenerChannel {
    pub tx: UnboundedSender<ListenerAction>,
    pub rx: Arc<Mutex<UnboundedReceiver<ListenerAction>>>,
}

// Channel for actions that should be done on the main thread
pub static ACTION_LISTENER: Lazy<ListenerChannel> = Lazy::new(|| {
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    ListenerChannel {
        tx,
        rx: Arc::new(Mutex::new(rx)),
    }
});

#[derive(Clone, PartialEq)]
pub struct AsyncRef<T> {
    inner_ref: Option<Vec<T>>,
}

impl<T> AsyncRef<T> {
    /// Appends a value to this queue
    pub fn append(&mut self, value: T) {
        match self.inner_ref.as_mut() {
            Some(current) => {
                current.push(value);
            }
            None => self.inner_ref = Some(vec![value]),
        };
    }
}

/// Create a handler for an async queue
/// Everytime a value gets added to the queue the future will be spawned when it rerenders
pub fn async_queue<T: 'static + Send, Fut>(
    cx: &ScopeState,
    fut: impl Fn(T) -> Fut,
) -> &UseRef<AsyncRef<T>>
where
    Fut: Future<Output = ()> + Send + 'static,
{
    let queue_ref: &UseRef<AsyncRef<T>> = use_ref(cx, || AsyncRef { inner_ref: None });
    if let Some(queue) = queue_ref.write_silent().inner_ref.take() {
        for entry in queue {
            let future = fut(entry);
            tokio::spawn(future);
        }
    }
    queue_ref
}

pub fn chat_upload_stream_handler(
    cx: &ScopeState,
) -> &UseRef<
    AsyncRef<(
        Uuid,
        Vec<String>,
        Vec<Location>,
        Option<Uuid>,
        AttachmentEventStream,
    )>,
> {
    async_queue(
        cx,
        |(conv_id, msg, attachments, appended_msg_id, mut stream): (
            Uuid,
            Vec<String>,
            Vec<Location>,
            Option<Uuid>,
            AttachmentEventStream,
        )| {
            async move {
                while let Some(kind) = stream.next().await {
                    match kind {
                        AttachmentKind::Pending(res) => {
                            if let Err(e) = res {
                                log::debug!("Error uploading file {}", e);
                            }
                            return;
                        }
                        AttachmentKind::AttachedProgress(progress) => {
                            if let Err(e) = WARP_EVENT_CH.tx.send(WarpEvent::Message(
                                MessageEvent::AttachmentProgress {
                                    progress,
                                    conversation_id: conv_id,
                                    msg: PendingMessage::for_compare(
                                        msg.clone(),
                                        &attachments,
                                        appended_msg_id,
                                    ),
                                },
                            )) {
                                log::error!("failed to send warp_event: {e}");
                            }
                        }
                    }
                }
            }
        },
    )
}

pub struct DownloadStreamData {
    pub stream: warp::constellation::ConstellationProgressStream,
    pub file: String,
    pub id: Uuid,
    pub on_finish: DownloadComplete,
    pub show_toast: bool,
    pub file_state: TransferState,
}

pub fn download_stream_handler(cx: &ScopeState) -> &UseRef<AsyncRef<DownloadStreamData>> {
    async_queue(
        cx,
        |DownloadStreamData {
             mut stream,
             file,
             id,
             on_finish,
             show_toast,
             file_state,
         }| {
            async move {
                let mut paused = false;
                loop {
                    tokio::select! {
                        biased;
                        true = file_state.matches(TransferStates::Cancel) => {
                            log::info!("{:?} file cancelled!", file);
                            let _ = ACTION_LISTENER
                                .tx
                                .send(ListenerAction::CancelTransfer { id, download: true });
                            sleep(Duration::from_secs(3)).await;
                            let _ = ACTION_LISTENER
                                .tx
                                .send(ListenerAction::FinishTransfer { id, download: true });
                            on_finish(true).await;
                            return;
                        },
                        true = file_state.matches(TransferStates::Pause) => {
                            if !paused {
                                let _ = ACTION_LISTENER
                                .tx
                                .send(ListenerAction::PauseTransfer { id, download: true });
                                paused = true;
                            }
                        },
                        progress = stream.next() => {
                            let Some(progress) = progress else {
                                break;
                            };
                            let _ = ACTION_LISTENER.tx.send(ListenerAction::TransferProgress {
                                id,
                                progression: progress.clone(),
                                download: true,
                            });
                            match progress {
                                Progression::ProgressComplete { name: _, total: _ } => break,
                                Progression::ProgressFailed { name: _, last_size: _ ,error: _ } => {
                                    sleep(Duration::from_secs(3)).await;
                                    let _ = ACTION_LISTENER
                                        .tx
                                        .send(ListenerAction::FinishTransfer { id, download: true });
                                    on_finish(true).await;
                                    return;
                                }
                                _ => {}
                            }
                        }
                    }
                }
                if show_toast {
                    let _ = ACTION_LISTENER.tx.send(ListenerAction::ToastAction {
                        title: "".into(),
                        content: get_local_text_with_args(
                            "files.download-success",
                            vec![("file", file)],
                        ),
                        icon: None,
                        timeout: 2,
                    });
                }
                let _ = ACTION_LISTENER
                    .tx
                    .send(ListenerAction::FinishTransfer { id, download: true });
                on_finish(false).await
            }
        },
    )
}
