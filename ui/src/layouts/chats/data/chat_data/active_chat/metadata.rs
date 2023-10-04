use common::state::{self, Identity, State};
use kit::components::indicator::Platform;
use uuid::Uuid;
use warp::{
    crypto::DID,
    raygun::{self, ConversationType},
};

#[derive(Debug, Default, Clone)]
pub struct Metadata {
    pub chat_id: Uuid,
    pub my_id: Identity,
    pub other_participants: Vec<Identity>,
    pub active_participant: Identity,
    pub subtext: String,
    pub is_favorite: bool,
    pub first_image: String,
    pub other_participants_names: String,
    pub platform: Platform,
    pub conversation_name: Option<String>,
    pub conversation_type: Option<ConversationType>,
    pub creator: Option<DID>,
    pub replying_to: Option<raygun::Message>,
    pub unreads: usize,
}

impl Metadata {
    pub fn new(s: &State, chat: &state::chats::Chat) -> Self {
        let participants = s.chat_participants(&chat);
        // warning: if a friend changes their username, if state.friends is updated, the old username would still be in state.chats
        // this would be "fixed" the next time uplink starts up
        let other_participants: Vec<Identity> = s.remove_self(&participants);
        let active_participant = other_participants
            .first()
            .cloned()
            .unwrap_or(s.get_own_identity());

        let subtext = match chat.conversation_type {
            ConversationType::Direct => active_participant.status_message().unwrap_or_default(),
            _ => String::new(),
        };
        let is_favorite = s.is_favorite(&chat);

        let first_image = active_participant.profile_picture();
        let other_participants_names = State::join_usernames(&other_participants);

        let platform = active_participant.platform().into();

        Self {
            chat_id: chat.id,
            other_participants,
            my_id: s.get_own_identity(),
            active_participant,
            subtext,
            is_favorite,
            first_image,
            other_participants_names,
            platform,
            conversation_name: chat.conversation_name.clone(),
            conversation_type: Some(chat.conversation_type),
            creator: chat.creator.clone(),
            replying_to: chat.replying_to.clone(),
            unreads: chat.unreads() as _,
        }
    }
}
