use std::rc::Rc;

use common::state::{Chat, Identity, State};
use dioxus::prelude::*;
use kit::components::indicator::Platform;
use uuid::Uuid;
use warp::raygun::ConversationType;

pub struct ChatData {
    pub active_chat: Chat,
    pub my_id: Identity,
    pub other_participants: Vec<Identity>,
    pub active_participant: Identity,
    pub subtext: String,
    pub is_favorite: bool,
    pub first_image: String,
    pub other_participants_names: String,
    pub platform: Platform,
}

impl PartialEq for ChatData {
    fn eq(&self, _other: &Self) -> bool {
        false
    }
}

impl ChatData {
    pub fn get(state: &UseSharedState<State>) -> Option<Rc<Self>> {
        let s = state.read();
        // the Compose page shouldn't be called before chats is initialized. but check here anyway.
        if !s.initialized {
            return None;
        }

        let active_chat = match s.get_active_chat() {
            Some(c) => c,
            None => return None,
        };
        let participants = s.chat_participants(&active_chat);
        // warning: if a friend changes their username, if state.friends is updated, the old username would still be in state.chats
        // this would be "fixed" the next time uplink starts up
        let other_participants: Vec<Identity> = s.remove_self(&participants);
        let active_participant = other_participants
            .first()
            .cloned()
            .unwrap_or(s.get_own_identity());

        let subtext = match active_chat.conversation_type {
            ConversationType::Direct => active_participant.status_message().unwrap_or_default(),
            _ => String::new(),
        };
        let is_favorite = s.is_favorite(&active_chat);

        let first_image = active_participant.profile_picture();
        let other_participants_names = State::join_usernames(&other_participants);

        // TODO: Pending new message divider implementation
        // let _new_message_text = LOCALES
        //     .lookup(&*APP_LANG.read(), "messages.new")
        //     .unwrap_or_default();

        let platform = active_participant.platform().into();

        let data = Rc::new(Self {
            active_chat,
            other_participants,
            my_id: s.get_own_identity(),
            active_participant,
            subtext,
            is_favorite,
            first_image,
            other_participants_names,
            platform,
        });

        Some(data)
    }
}

#[derive(PartialEq, Props)]
pub struct ChatProps {
    #[props(!optional)]
    pub data: Option<Rc<ChatData>>,
    pub show_edit_group: UseState<Option<Uuid>>,
    pub show_group_users: UseState<Option<Uuid>>,
    pub ignore_focus: bool,
    pub is_owner: bool,
    pub is_edit_group: bool,
}
