use std::collections::HashMap;

use uuid::Uuid;
use warp::{constellation::Progression, crypto::DID, raygun::Location};

use crate::warp_runner::ui_adapter::Message;
// We can improve message equality detection if warp e.g. can send us their assigned uuid.
// Else it is just a guesswork
#[derive(Clone, Debug)]
pub struct PendingMessage {
    pub attachments_progress: HashMap<String, Progression>,
    pub message: Message,
}

impl PendingMessage {
    pub fn new(
        chat_id: Uuid,
        did: DID,
        message_id: Uuid,
        text: Vec<String>,
        attachments: &[Location],
    ) -> Self {
        // Create a dummy message
        let mut inner = warp::raygun::Message::default();
        inner.set_id(message_id);
        inner.set_sender(did);
        inner.set_conversation_id(chat_id);
        inner.set_lines(text);
        let message = Message::new(inner, None, Uuid::new_v4().to_string());
        PendingMessage {
            attachments_progress: HashMap::new(),
            message,
        }
    }

    pub fn id(&self) -> Uuid {
        self.message.inner.id()
    }
}

impl PartialEq for PendingMessage {
    fn eq(&self, other: &Self) -> bool {
        self.id().eq(&other.id())
    }
}

impl Eq for PendingMessage {}

pub fn progress_file(progress: &Progression) -> String {
    match progress {
        Progression::CurrentProgress {
            name,
            current: _,
            total: _,
        } => name.clone(),
        Progression::ProgressComplete { name, total: _ } => name.clone(),
        Progression::ProgressFailed {
            name,
            last_size: _,
            error: _,
        } => name.clone(),
    }
}
