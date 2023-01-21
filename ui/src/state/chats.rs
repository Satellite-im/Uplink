use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use uuid::Uuid;
use warp::raygun::Message;

use super::identity::Identity;

#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
pub struct Chat {
    // Warp generated UUID of the chat
    // TODO: This should be wired up to warp conversation id's
    #[serde(default)]
    pub id: Uuid,
    // Includes the list of participants within a given chat.
    // these don't need to be stored in state either
    #[serde(skip)]
    pub participants: Vec<Identity>,
    // Messages should only contain messages we want to render. Do not include the entire message history.
    // don't store the actual message in state
    #[serde(skip)]
    pub messages: Vec<Message>,
    // Unread count for this chat, should be cleared when we view the chat.
    #[serde(default)]
    pub unreads: u32,
    // If a value exists, we will render the message we're replying to above the chatbar
    #[serde(skip)]
    pub replying_to: Option<Message>,
}

// TODO: Properly wrap data which is expected to persist remotely in options, so we can know if we're still figuring out what exists "remotely", i.e. loading.
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Chats {
    #[serde(skip)]
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

impl Chats {
    pub fn join(&mut self, mut other: HashMap<Uuid, Chat>) {
        for (k, v) in other.drain() {
            self.all.insert(k, v);
        }
    }
}
