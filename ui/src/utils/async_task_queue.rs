use common::{
    icons::outline::Shape as Icon,
    language::get_local_text_with_args,
    state::pending_message::PendingMessage,
    warp_runner::{ui_adapter::MessageEvent, WarpEvent},
    WARP_EVENT_CH,
};
use dioxus_core::ScopeState;
use dioxus_hooks::{use_ref, Signal};
use futures::{Future, StreamExt};
use tokio::sync::{
    mpsc::{UnboundedReceiver, UnboundedSender},
    Mutex,
};

use once_cell::sync::Lazy;
use std::sync::Arc;
use uuid::Uuid;
use warp::raygun::{AttachmentEventStream, AttachmentKind, Location};

pub enum ListenerAction {
    ToastAction {
        title: String,
        content: String,
        icon: Option<Icon>,
        timeout: u32,
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
pub fn async_queue<T: 'static + Send, Fut>(fut: impl Fn(T) -> Fut) -> &Signal<AsyncRef<T>>
where
    Fut: Future<Output = ()> + Send + 'static,
{
    let queue_ref: &Signal<AsyncRef<T>> = use_signal(|| AsyncRef { inner_ref: None });
    if let Some(queue) = queue_ref.write_silent().inner_ref.take() {
        for entry in queue {
            let future = fut(entry);
            tokio::spawn(future);
        }
    }
    queue_ref
}

pub fn chat_upload_stream_handler() -> &Signal<
    AsyncRef<(
        Uuid,
        Vec<String>,
        Vec<Location>,
        Option<Uuid>,
        AttachmentEventStream,
    )>,
> {
    async_queue(
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

pub fn download_stream_handler() -> &Signal<
    AsyncRef<(
        warp::constellation::ConstellationProgressStream,
        String,
        std::pin::Pin<Box<dyn Future<Output = ()> + Send>>,
        bool,
    )>,
> {
    async_queue(
        |(mut stream, file, on_finish, should_show_toast_notification): (
            warp::constellation::ConstellationProgressStream,
            String,
            std::pin::Pin<Box<dyn Future<Output = ()> + Send>>,
            bool,
        )| {
            async move {
                while let Some(p) = stream.next().await {
                    log::debug!("download progress: {p:?}");
                }
                if should_show_toast_notification {
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
                on_finish.await
            }
        },
    )
}
