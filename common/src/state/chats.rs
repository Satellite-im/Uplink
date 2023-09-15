use std::{
    collections::{HashMap, HashSet, VecDeque},
    time::Instant,
};

use chrono::{DateTime, Utc};
use serde::{ser::SerializeStruct, Deserialize, Serialize, Serializer};
use uuid::Uuid;
use warp::{
    constellation::Progression,
    crypto::DID,
    raygun::{self, ConversationType, Location},
};

use crate::{warp_runner::ui_adapter, STATIC_ARGS};

use super::pending_message::{progress_file, PendingMessage};

// let (p = window_bottom) be an index into Chat.messages
// show messages from (p - window_size) to (p + window_extra)
// scroll up by window_extra (this allows an onmouseout event to trigger)
// pub struct ChatView {
//     // the idx of the message on the bottom of the screen
//     message_idx: usize,
//     // the number of messages to render in the window
//     window_size: usize,
//     // the number of messages to add outside the window, for scrolling purposes
//     window_extra: usize,
// }

// warning: Chat implements Serialize
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
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
    // Messages should only contain messages we want to render. Do not include the entire message history.
    // don't store the actual message in state
    // warn: Chat has a custom serialize method which skips this field when not using mock data.
    #[serde(default)]
    pub messages: VecDeque<ui_adapter::Message>,
    // Unread count for this chat, should be cleared when we view the chat.
    pub unreads: u32,
    // If a value exists, we will render the message we're replying to above the chatbar
    #[serde(skip)]
    pub replying_to: Option<raygun::Message>,
    // list of users currently typing.
    // (user id, last update time)
    #[serde(skip)]
    pub typing_indicator: HashMap<DID, Instant>,
    #[serde(skip)]
    pub draft: Option<String>,
    // for loading messages into the UI - indicates if more messages can be fetched from warp and added to Chat.messages
    #[serde(skip)]
    pub has_more_messages: bool,
    #[serde(skip)]
    pub pending_outgoing_messages: Vec<PendingMessage>,
    #[serde(skip)]
    pub files_attached_to_send: Vec<Location>,
    #[serde(skip)]
    pub scroll_value: Option<i64>,
    #[serde(skip)]
    pub pinned_messages: Vec<raygun::Message>,
    #[serde(skip, default)]
    pub scroll_to: Option<Uuid>,
}

impl Chat {
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

    // take the timestamp of a message and determine if it occurs at or after the time of the earliest unread message
    // WARNING: a chat is loaded with 10 or 20 messages by default. if there are more unread messages in RayGun, then
    // this function could return a false negative. This is unlikely.
    pub fn is_msg_unread(&self, message_time: DateTime<Utc>) -> bool {
        if self.unreads == 0 {
            return false;
        }
        // if you have 1 unread message, skip 0 messages and take the next one.
        // if you have 2 unread messages, skip 1 and take the next one.
        let to_skip = self.unreads.saturating_sub(1);
        match self.messages.iter().rev().nth(to_skip as usize) {
            Some(msg) => msg.inner.date() <= message_time,
            _ => false,
        }
    }
}

// warning: Chats implements Serialize
#[derive(Clone, Debug, Default, Deserialize)]
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
            Some(c) => c.unreads > 0,
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

fn default_conversation_type() -> ConversationType {
    ConversationType::Direct
}

impl Serialize for Chats {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let mut state = serializer.serialize_struct("Chats", 5)?;

        state.serialize_field("all", &self.all)?;
        state.serialize_field("active", &self.active)?;
        state.skip_field("active_media")?;
        state.serialize_field("in_sidebar", &self.in_sidebar)?;
        state.serialize_field("favorites", &self.favorites)?;

        state.end()
    }
}

// don't skip messages and participants when using mock data
impl Serialize for Chat {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let mut state = serializer.serialize_struct("Chat", 6)?;
        state.serialize_field("id", &self.id)?;
        state.serialize_field("participants", &self.participants)?;
        state.serialize_field("conversation_type", &self.conversation_type)?;
        state.serialize_field("creator", &self.creator)?;

        if STATIC_ARGS.use_mock {
            state.serialize_field("messages", &self.messages)?;
        } else {
            state.skip_field("messages")?;
        }

        state.serialize_field("unreads", &self.unreads)?;
        state.skip_field("replying_to")?;
        state.end()
    }
}
