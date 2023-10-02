use std::{
    collections::{HashMap, VecDeque},
    time::Instant,
};

use common::{
    state::{self, Identity, State},
    warp_runner::ui_adapter,
};
use kit::components::indicator::Platform;
use uuid::Uuid;
use warp::{
    crypto::DID,
    raygun::{self, ConversationType},
};

mod message_view;
mod messages;
mod metadata;
mod partial_message;
pub use message_view::*;
pub use messages::*;
pub use metadata::*;
pub use partial_message::*;

#[derive(Debug, Default, Clone)]
pub struct ActiveChat {
    metadata: Metadata,
    pub messages: Messages,
    pub is_initialized: bool,
    pub typing_indicator: HashMap<DID, Instant>,
    pub pinned_messages: Vec<raygun::Message>,
    pub scrolled_once: bool,
}

impl ActiveChat {
    pub fn new(
        s: &State,
        chat: &state::chats::Chat,
        messages: VecDeque<ui_adapter::Message>,
    ) -> Self {
        Self {
            metadata: Metadata::new(s, chat),
            messages: Messages::new(messages),
            is_initialized: true,
            typing_indicator: HashMap::new(),
            pinned_messages: chat.pinned_messages.clone(),
            scrolled_once: false,
        }
    }

    pub fn messages(&self) -> VecDeque<ui_adapter::Message> {
        self.messages.messages.clone()
    }
}

// simplify access to metadata fields
impl ActiveChat {
    pub fn id(&self) -> Uuid {
        self.metadata.chat_id
    }
    pub fn my_id(&self) -> Identity {
        self.metadata.my_id.clone()
    }
    pub fn other_participants(&self) -> Vec<Identity> {
        self.metadata.other_participants.clone()
    }
    pub fn active_participant(&self) -> Identity {
        self.metadata.active_participant.clone()
    }
    pub fn subtext(&self) -> String {
        self.metadata.subtext.clone()
    }
    pub fn is_favorite(&self) -> bool {
        self.metadata.is_favorite
    }
    pub fn first_image(&self) -> String {
        self.metadata.first_image.clone()
    }
    pub fn other_participants_names(&self) -> String {
        self.metadata.other_participants_names.clone()
    }
    pub fn platform(&self) -> Platform {
        self.metadata.platform
    }
    pub fn conversation_name(&self) -> Option<String> {
        self.metadata.conversation_name.clone()
    }
    pub fn conversation_type(&self) -> ConversationType {
        self.metadata
            .conversation_type
            .unwrap_or(ConversationType::Direct)
    }
    pub fn creator(&self) -> Option<DID> {
        self.metadata.creator.clone()
    }

    pub fn replying_to(&self) -> Option<raygun::Message> {
        self.metadata.replying_to.clone()
    }
}
