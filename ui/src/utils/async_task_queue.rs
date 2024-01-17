use common::icons::outline::Shape as Icon;
use dioxus_core::ScopeState;
use dioxus_hooks::{use_ref, UseRef};
use futures::Future;
use tokio::sync::{
    mpsc::{UnboundedReceiver, UnboundedSender},
    Mutex,
};

use once_cell::sync::Lazy;
use std::sync::Arc;

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
