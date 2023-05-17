use std::{collections::HashMap, path::PathBuf};

use uuid::Uuid;
use warp::{constellation::Progression, crypto::DID};

use crate::warp_runner::ui_adapter::Message;

use super::State;

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
                m.attachments.insert(file, Some(progress));
                break;
            }
        }
    }

    pub fn finish(&mut self, msg: Vec<String>, attachments: Vec<String>) {
        let opt = self
            .msg
            .iter()
            .position(|e| e.text.eq(&msg) && e.attachments.keys().all(|a| attachments.contains(a)));
        if let Some(pending) = opt {
            self.msg.remove(pending);
        }
    }
}

#[derive(Clone, Debug)]
pub struct PendingSentMessage {
    text: Vec<String>,
    attachments: HashMap<String, Option<Progression>>,
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
            attachments: {
                let mut m = HashMap::new();
                attachments.iter().for_each(|p| {
                    if let Some(name) = p.file_name().map(|ostr| ostr.to_str().unwrap_or_default())
                    {
                        if !name.is_empty() {
                            m.insert(name.to_string(), None);
                        }
                    }
                });
                m
            },
            message,
        }
    }

    pub fn new(chat_id: Uuid, did: DID, text: Vec<String>, attachments: &Vec<PathBuf>) -> Self {
        let mut inner = warp::raygun::Message::default();
        inner.set_sender(did);
        inner.set_conversation_id(chat_id);
        inner.set_value(text.clone());

        let message = Message {
            inner,
            in_reply_to: None,
            key: String::new(),
        };
        PendingSentMessage {
            text,
            attachments: {
                let mut m = HashMap::new();
                attachments.iter().for_each(|p| {
                    if let Some(name) = p.file_name().map(|ostr| ostr.to_str().unwrap_or_default())
                    {
                        if !name.is_empty() {
                            m.insert(name.to_string(), None);
                        }
                    }
                });
                m
            },
            message,
        }
    }
}

impl PartialEq for PendingSentMessage {
    fn eq(&self, other: &Self) -> bool {
        self.text.eq(&other.text)
            && self
                .attachments
                .keys()
                .all(|k| other.attachments.contains_key(k))
    }
}

impl Eq for PendingSentMessage {}
