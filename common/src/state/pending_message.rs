use std::{collections::HashMap, path::PathBuf, sync::Arc};

use once_cell::sync::Lazy;
use tokio::sync::{
    mpsc::{UnboundedReceiver, UnboundedSender},
    Mutex,
};
use uuid::Uuid;
use warp::{constellation::Progression, crypto::DID};

use crate::warp_runner::ui_adapter::Message;

pub struct AttachmentProgress {
    pub progress: Progression,
    pub conversation_id: Uuid,
    pub msg: PendingSentMessage,
}

pub struct PendingMessageChannels {
    pub tx: UnboundedSender<AttachmentProgress>,
    pub rx: Arc<Mutex<UnboundedReceiver<AttachmentProgress>>>,
}

pub static MESSAGE_CHANNEL: Lazy<PendingMessageChannels> = Lazy::new(|| {
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    PendingMessageChannels {
        tx,
        rx: Arc::new(Mutex::new(rx)),
    }
});

#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct PendingSentMessages {
    pub msg: Vec<PendingSentMessage>,
}

impl PendingSentMessages {
    pub fn new() -> Self {
        PendingSentMessages { msg: vec![] }
    }

    pub fn append(
        &mut self,
        chat_id: Uuid,
        did: DID,
        msg: Vec<String>,
        attachments: &Vec<PathBuf>,
    ) {
        self.msg
            .push(PendingSentMessage::new(chat_id, did, msg, &attachments));
    }

    pub fn update(&mut self, msg: PendingSentMessage, progress: Progression) {
        let file = match progress.clone() {
            Progression::CurrentProgress {
                name,
                current: _,
                total: _,
            } => name,
            Progression::ProgressComplete { name, total: _ } => name,
            Progression::ProgressFailed {
                name,
                last_size: _,
                error: _,
            } => name,
        };
        for m in &mut self.msg {
            if msg.eq(m) {
                m.attachments_progress.insert(file, Some(progress));
                break;
            }
        }
    }

    pub fn finish(&mut self, msg: Vec<String>, attachments: Vec<String>) {
        let opt = self.msg.iter().position(|e| {
            e.text.eq(&msg)
                && e.attachments_progress
                    .keys()
                    .all(|a| attachments.contains(a))
        });
        if let Some(pending) = opt {
            self.msg.remove(pending);
        }
    }
}

#[derive(Clone, Debug)]
pub struct PendingSentMessage {
    text: Vec<String>,
    attachments: Vec<String>,
    pub attachments_progress: HashMap<String, Option<Progression>>,
    pub message: Message,
}

impl PendingSentMessage {
    // Use this for comparison cases
    pub fn for_compare(text: Vec<String>, attachments: &Vec<PathBuf>) -> Self {
        let message = Message {
            inner: warp::raygun::Message::default(),
            in_reply_to: None,
            key: String::new(),
        };
        PendingSentMessage {
            text,
            attachments: attachments
                .iter()
                .map(|p| {
                    if let Some(name) = p.file_name().map(|ostr| ostr.to_str().unwrap_or_default())
                    {
                        return name.to_string();
                    }
                    String::new()
                })
                .collect(),
            attachments_progress: HashMap::new(),
            message,
        }
    }

    pub fn new(chat_id: Uuid, did: DID, text: Vec<String>, attachments: &Vec<PathBuf>) -> Self {
        // Create a dummy message
        let mut inner = warp::raygun::Message::default();
        inner.set_id(Uuid::new_v4());
        inner.set_sender(did);
        inner.set_conversation_id(chat_id);
        inner.set_value(text.clone());

        let message = Message {
            inner,
            in_reply_to: None,
            key: Uuid::new_v4().to_string(),
        };
        PendingSentMessage {
            text,
            attachments: attachments
                .iter()
                .map(|p| {
                    if let Some(name) = p.file_name().map(|ostr| ostr.to_str().unwrap_or_default())
                    {
                        return name.to_string();
                    }
                    String::new()
                })
                .collect(),
            attachments_progress: HashMap::new(),
            message,
        }
    }
}

impl PartialEq for PendingSentMessage {
    fn eq(&self, other: &Self) -> bool {
        self.text.eq(&other.text)
            && self
                .attachments
                .iter()
                .all(|k| other.attachments.contains(k))
    }
}

impl Eq for PendingSentMessage {}
