use std::collections::{HashMap, VecDeque};

use common::{
    state::{Identity, State},
    warp_runner::ui_adapter,
};
use dioxus::prelude::*;

use kit::components::indicator::Platform;
use uuid::Uuid;
use warp::raygun::ConversationType;

use super::{ActiveChat, ChatBehavior};

#[derive(Clone, Default)]
pub struct ChatData {
    pub active_chat: ActiveChat,
    pub chat_behaviors: HashMap<Uuid, ChatBehavior>,
}

impl PartialEq for ChatData {
    fn eq(&self, _other: &Self) -> bool {
        false
    }
}

impl ChatData {
    // call this first to fetch the messages
    pub fn get_chat_behavior(&self, id: Uuid) -> ChatBehavior {
        self.chat_behaviors.get(&id).cloned().unwrap_or_default()
    }

    // after the messages have been fetched, init the active chat
    pub fn set_active_chat(
        &mut self,
        s: &State,
        chat: &common::state::Chat,
        behavior: ChatBehavior,
        messages: VecDeque<ui_adapter::Message>,
    ) {
        self.chat_behaviors.insert(chat.id, behavior);
        self.active_chat = ActiveChat::new(s, chat, messages);
    }
}

#[derive(PartialEq, Props)]
pub struct ChatProps {
    pub show_edit_group: UseState<Option<Uuid>>,
    pub show_group_users: UseState<Option<Uuid>>,
    pub ignore_focus: bool,
    pub is_owner: bool,
    pub is_edit_group: bool,
}
