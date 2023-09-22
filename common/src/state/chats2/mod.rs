mod chat_behavior;
mod message_indices;
mod msg_range;
mod scroll_behavior;
mod view_behavior;

pub use chat_behavior::*;
pub use message_indices::*;
pub use msg_range::*;
pub use scroll_behavior::*;
pub use view_behavior::*;

use std::{
    collections::{HashMap, HashSet, VecDeque},
    time::Instant,
};

use serde::{Deserialize, Serialize};
use uuid::Uuid;
use warp::{
    constellation::Progression,
    crypto::DID,
    raygun::{self, ConversationType, Location},
};

use super::pending_message::{progress_file, PendingMessage};

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Chats {
    // All active chats from warp.
    pub all: HashMap<Uuid, Chat>,
    // Chat to display / interact with currently.
    pub active: Option<Uuid>,
    // don't persist a call across restarts
    // the Uuid is the chat associated with the current call
    #[serde(skip)]
    pub active_media: Option<Uuid>, // TODO: in the future, this should probably be a vec of media streams or something
    // Chats to show in the sidebar
    pub in_sidebar: VecDeque<Uuid>,
    // Favorite Chats
    pub favorites: Vec<Uuid>,
}

impl Chats {
    pub fn active_chat_has_unreads(&self) -> bool {
        let id = match self.active {
            Some(c) => c,
            None => return false,
        };

        match self.all.get(&id) {
            Some(c) => c.unreads() > 0,
            None => false,
        }
    }

    /// returns the UUID of the message being replied to by the active chat
    pub fn get_replying_to(&self) -> Option<Uuid> {
        self.active.and_then(|id| {
            self.all
                .get(&id)
                .and_then(|chat| chat.replying_to.as_ref().map(|msg| msg.id()))
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Chat {
    // Warp generated UUID of the chat
    // TODO: This should be wired up to warp conversation id's
    pub id: Uuid,
    // Includes the list of participants within a given chat.
    // these don't need to be stored in state either
    pub participants: HashSet<DID>,
    // this makes it easier to tell direct conversations from group conversations. There should be no group conversations with only 2 participants.
    #[serde(default = "default_conversation_type")]
    pub conversation_type: ConversationType,
    // only Some for group chats
    #[serde(default)]
    pub conversation_name: Option<String>,
    // Only for group chats
    #[serde(default)]
    pub creator: Option<DID>,
    // used for the sidebar
    #[serde(default)]
    pub most_recent_message: Option<String>,
    // todo: make this not pub
    #[serde(default)]
    pub chat_behavior: ChatBehavior,
    // Unread count for this chat, should be cleared when we view the chat.
    #[serde(default)]
    unreads: HashSet<Uuid>,
    // If a value exists, we will render the message we're replying to above the chatbar
    #[serde(skip)]
    pub replying_to: Option<raygun::Message>,
    // list of users currently typing.
    // (user id, last update time)
    #[serde(skip)]
    pub typing_indicator: HashMap<DID, Instant>,
    #[serde(skip)]
    pub draft: Option<String>,
    #[serde(skip)]
    pub pending_outgoing_messages: Vec<PendingMessage>,
    #[serde(skip)]
    pub files_attached_to_send: Vec<Location>,
    #[serde(skip)]
    pub pinned_messages: Vec<raygun::Message>,
}

impl Chat {
    pub fn new(
        id: Uuid,
        participants: HashSet<DID>,
        conversation_type: ConversationType,
        conversation_name: Option<String>,
        creator: Option<DID>,
        most_recent_message: Option<String>,
        pinned_messages: Vec<raygun::Message>,
    ) -> Self {
        Self {
            id,
            participants,
            conversation_type,
            conversation_name,
            creator,
            most_recent_message,
            chat_behavior: ChatBehavior::default(),
            unreads: HashSet::new(),
            replying_to: None,
            typing_indicator: HashMap::new(),
            draft: None,
            pending_outgoing_messages: vec![],
            files_attached_to_send: Vec::new(),
            pinned_messages,
        }
    }
    pub fn append_pending_msg(
        &mut self,
        chat_id: Uuid,
        did: DID,
        msg: Vec<String>,
        attachments: &[Location],
    ) -> Uuid {
        let new = PendingMessage::new(chat_id, did, msg, attachments);
        let uuid = new.message.inner.id();
        self.pending_outgoing_messages.push(new);
        uuid
    }

    pub fn update_pending_msg(&mut self, msg: PendingMessage, progress: Progression) {
        let file = progress_file(&progress);
        for m in &mut self.pending_outgoing_messages {
            if msg.eq(m) {
                m.attachments_progress.insert(file, progress);
                break;
            }
        }
    }

    pub fn remove_pending_msg(
        &mut self,
        msg: Vec<String>,
        attachments: Vec<String>,
        uuid: Option<Uuid>,
    ) {
        let opt = self.pending_outgoing_messages.iter().position(|e| {
            e.message.inner.value().eq(&msg)
                && e.attachments_progress
                    .keys()
                    .all(|a| attachments.contains(a))
                && uuid.map(|id| id.eq(&e.id())).unwrap_or(true)
        });
        if let Some(pending) = opt {
            self.pending_outgoing_messages.remove(pending);
        }
    }

    pub fn unreads(&self) -> u32 {
        self.unreads.len() as _
    }

    pub fn clear_unreads(&mut self) {
        self.unreads.clear();
    }

    pub fn remove_unread(&mut self, id: &Uuid) -> bool {
        self.unreads.remove(id)
    }

    pub fn add_unread(&mut self, id: Uuid) {
        self.unreads.insert(id);
    }
}

fn default_conversation_type() -> ConversationType {
    ConversationType::Direct
}
