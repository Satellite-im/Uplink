use std::collections::VecDeque;

use common::{
    state::{self, Identity, State},
    warp_runner::ui_adapter,
};
use kit::components::indicator::Platform;
use uuid::Uuid;
use warp::{crypto::DID, raygun::ConversationType};

mod messages;
mod metadata;
pub use messages::*;
pub use metadata::*;

#[derive(Debug, Default, Clone)]
pub struct ActiveChat {
    metadata: Metadata,
    pub messages: Messages,
    pub is_initialized: bool,
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
        }
    }

    pub fn id(&self) -> Uuid {
        self.metadata.chat_id
    }
    pub fn my_id(&self) -> Identity {
        self.metadata.my_id
    }
    pub fn other_participants(&self) -> Vec<Identity> {
        self.metadata.other_participants
    }
    pub fn active_participant(&self) -> Identity {
        self.metadata.active_participant
    }
    pub fn subtext(&self) -> String {
        self.metadata.subtext
    }
    pub fn is_favorite(&self) -> bool {
        self.metadata.is_favorite
    }
    pub fn first_image(&self) -> String {
        self.metadata.first_image
    }
    pub fn other_participants_names(&self) -> String {
        self.metadata.other_participants_names
    }
    pub fn platform(&self) -> Platform {
        self.metadata.platform
    }
    pub fn conversation_name(&self) -> Option<String> {
        self.metadata.conversation_name
    }
    pub fn conversation_type(&self) -> ConversationType {
        self.metadata
            .conversation_type
            .unwrap_or(ConversationType::Direct)
    }
    pub fn creator(&self) -> Option<DID> {
        self.metadata.creator
    }
}
