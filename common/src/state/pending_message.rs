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

    pub fn get(&self, msg: PendingSentMessage) -> Option<&PendingSentMessage> {
        self.msg.iter().find(|m| msg.eq(*m))
    }

    pub fn append(
        &mut self,
        chat_id: Uuid,
        did: DID,
        msg: Vec<String>,
        attachments: &[PathBuf],
    ) -> Uuid {
        let new = PendingSentMessage::new(chat_id, did, msg, attachments);
        let uuid = new.message.inner.id();
        self.msg.push(new);
        uuid
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
                m.attachments_progress.insert(file, progress);
                break;
            }
        }
    }

    pub fn finish(&mut self, msg: Vec<String>, attachments: Vec<String>, uuid: Option<Uuid>) {
        let opt = self.msg.iter().position(|e| {
            e.text.eq(&msg)
                && e.attachments_progress
                    .keys()
                    .all(|a| attachments.contains(a))
                && uuid.map(|id| id.eq(&e.id())).unwrap_or(true)
        });
        if let Some(pending) = opt {
            self.msg.remove(pending);
        }
    }
}

//We can improve message equality detection if warp e.g. can send us their assigned uuid.
//Else it is just a guesswork
#[derive(Clone, Debug)]
pub struct PendingSentMessage {
    text: Vec<String>,
    attachments: Vec<String>,
    pub attachments_progress: HashMap<String, Progression>,
    pub message: Message,
}

impl PendingSentMessage {
    // Use this for comparison cases
    pub fn for_compare(text: Vec<String>, attachments: &[PathBuf], id: Option<Uuid>) -> Self {
        let mut inner = warp::raygun::Message::default();
        if let Some(m_id) = id {
            inner.set_id(m_id);
        }
        let message = Message {
            inner,
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

    pub fn new(chat_id: Uuid, did: DID, text: Vec<String>, attachments: &[PathBuf]) -> Self {
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

    // UI side id. Messages arriving at warp have a different id!
    // This is only for messages that have not been sent to warp yet
    pub fn id(&self) -> Uuid {
        self.message.inner.id()
    }
}

impl PartialEq for PendingSentMessage {
    fn eq(&self, other: &Self) -> bool {
        self.text.eq(&other.text)
            && self
                .attachments
                .iter()
                .all(|k| other.attachments.contains(k))
            && self.id().eq(&other.id())
    }
}

impl Eq for PendingSentMessage {}
