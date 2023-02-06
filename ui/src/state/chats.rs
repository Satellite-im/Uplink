use std::{
    collections::{HashMap, VecDeque},
    time::Instant,
};

use serde::{ser::SerializeStruct, Deserialize, Serialize, Serializer};
use uuid::Uuid;
use warp::{crypto::DID, raygun::Message};

use crate::STATIC_ARGS;

use super::identity::Identity;

// warning: Chat implements Serialize
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct Chat {
    // Warp generated UUID of the chat
    // TODO: This should be wired up to warp conversation id's
    #[serde(default)]
    pub id: Uuid,
    // Includes the list of participants within a given chat.
    // these don't need to be stored in state either
    #[serde(default)]
    pub participants: Vec<Identity>,
    // Messages should only contain messages we want to render. Do not include the entire message history.
    // don't store the actual message in state
    #[serde(default)]
    pub messages: VecDeque<Message>,
    // Unread count for this chat, should be cleared when we view the chat.
    #[serde(default)]
    pub unreads: u32,
    // If a value exists, we will render the message we're replying to above the chatbar
    #[serde(skip)]
    pub replying_to: Option<Message>,
    // list of users currently typing.
    // (user id, last update time)
    #[serde(skip)]
    pub typing_indicator: HashMap<DID, Instant>,
}

// warning: Chats implements Serialize
#[derive(Clone, Debug, Default, Deserialize)]
pub struct Chats {
    #[serde(default)]
    pub initialized: bool,
    // All active chats from warp.
    #[serde(default)]
    pub all: HashMap<Uuid, Chat>,
    // Chat to display / interact with currently.
    #[serde(default)]
    pub active: Option<Uuid>,
    // don't persist a call across restarts
    // the Uuid is the chat associated with the current call
    #[serde(skip)]
    pub active_media: Option<Uuid>, // TODO: in the future, this should probably be a vec of media streams or something
    // Chats to show in the sidebar
    #[serde(default)]
    pub in_sidebar: Vec<Uuid>,
    // Favorite Chats
    #[serde(default)]
    pub favorites: Vec<Uuid>,
}
pub enum Direction {
    Incoming,
    Outgoing,
}

impl Serialize for Chats {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let mut state = serializer.serialize_struct("Chats", 6)?;

        if STATIC_ARGS.use_mock {
            state.serialize_field("initialized", &self.initialized)?;
        } else {
            state.skip_field("initialized")?;
        }

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
        let mut state = serializer.serialize_struct("Chat", 5)?;
        state.serialize_field("id", &self.id)?;

        if STATIC_ARGS.use_mock {
            state.serialize_field("participants", &self.participants)?;
            state.serialize_field("messages", &self.messages)?;
        } else {
            state.skip_field("participants")?;
            state.skip_field("messages")?;
        }

        state.serialize_field("unreads", &self.unreads)?;
        state.skip_field("replying_to")?;
        state.end()
    }
}
