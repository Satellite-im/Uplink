use std::{
    collections::{HashMap, HashSet, VecDeque},
    time::Instant,
};

use serde::{ser::SerializeStruct, Deserialize, Serialize, Serializer};
use uuid::Uuid;
use warp::{
    constellation::Progression,
    crypto::DID,
    raygun::{self, ConversationType, Location},
};

use crate::{warp_runner::ui_adapter, STATIC_ARGS};

use super::pending_message::{progress_file, PendingMessage};
use dioxus_signals::Signal;

pub type Chat = ChatBase<Signal<ui_adapter::Message>>;

// A version that can be send across threads. Used for warp events
pub type SendableChat = ChatBase<ui_adapter::Message>;

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
#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct ChatBase<T> {
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
    #[serde(default = "default_deque")]
    pub messages: VecDeque<T>,
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
    // for loading messages into the UI - indicates if more messages can be fetched from warp and added to Chat.messages
    #[serde(skip)]
    pub has_more_messages: bool,
    #[serde(skip)]
    pub pending_outgoing_messages: Vec<PendingMessage>,
    #[serde(skip)]
    pub files_attached_to_send: Vec<Location>,
    // used to determine number of unread messages, for the active chat
    #[serde(skip)]
    pub is_scrolled: bool,
    #[serde(skip)]
    pub pinned_messages: Vec<raygun::Message>,
}

// can't derive default because there is no default conversation_type
impl<T> Default for ChatBase<T> {
    fn default() -> Self {
        Self {
            id: Default::default(),
            participants: Default::default(),
            conversation_type: ConversationType::Direct,
            conversation_name: Default::default(),
            creator: Default::default(),
            messages: Default::default(),
            unreads: Default::default(),
            replying_to: Default::default(),
            typing_indicator: Default::default(),
            draft: Default::default(),
            has_more_messages: Default::default(),
            pending_outgoing_messages: Default::default(),
            files_attached_to_send: Default::default(),
            is_scrolled: false,
            pinned_messages: Default::default(),
        }
    }
}

impl Eq for Chat {}

impl<T> ChatBase<T> {
    pub fn new(
        id: Uuid,
        participants: HashSet<DID>,
        conversation_type: ConversationType,
        conversation_name: Option<String>,
        creator: Option<DID>,
        messages: VecDeque<T>,
        pinned_messages: Vec<raygun::Message>,
    ) -> Self {
        Self {
            id,
            participants,
            conversation_type,
            conversation_name,
            creator,
            messages,
            pinned_messages,
            ..Default::default()
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

impl From<SendableChat> for Chat {
    fn from(mut value: SendableChat) -> Chat {
        Chat {
            id: value.id,
            participants: value.participants,
            conversation_type: value.conversation_type,
            conversation_name: value.conversation_name,
            creator: value.creator,
            messages: value
                .messages
                .drain(0..)
                .map(Signal::new)
                .collect::<VecDeque<_>>(),
            unreads: value.unreads,
            replying_to: value.replying_to,
            typing_indicator: value.typing_indicator,
            draft: value.draft,
            has_more_messages: value.has_more_messages,
            pending_outgoing_messages: value.pending_outgoing_messages,
            files_attached_to_send: value.files_attached_to_send,
            pinned_messages: value.pinned_messages,
            is_scrolled: false,
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
            Some(c) => c.unreads() > 0,
            None => false,
        }
    }

    pub fn active_chat_is_scrolled(&self) -> bool {
        let id = match self.active {
            Some(c) => c,
            None => return false,
        };
        self.all.get(&id).map(|c| c.is_scrolled).unwrap_or_default()
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

// For some reason with generics this is needed
fn default_deque<T>() -> VecDeque<T> {
    VecDeque::new()
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
