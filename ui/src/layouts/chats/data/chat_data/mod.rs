use std::collections::{HashMap, VecDeque};

use common::{state::State, warp_runner::ui_adapter};

use uuid::Uuid;

mod active_chat;
mod chat_behavior;

pub use active_chat::*;
pub use chat_behavior::*;

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
        chat_id: &Uuid,
        behavior: ChatBehavior,
        mut messages: Vec<ui_adapter::Message>,
    ) {
        if let Some(chat) = s.get_chat_by_id(*chat_id) {
            self.chat_behaviors.insert(chat.id, behavior);
            self.active_chat = ActiveChat::new(s, &chat, VecDeque::from_iter(messages.drain(..)));
        }
    }

    // returns true if the struct was mutated
    pub fn new_message(&mut self, conv_id: Uuid, msg: ui_adapter::Message) -> bool {
        if conv_id != self.active_chat.id() {
            return false;
        }

        let should_append_msg = self
            .chat_behaviors
            .get(&conv_id)
            .map(|behavior| behavior.view_init.scroll_to == ScrollTo::MostRecent)
            .unwrap_or_default();

        if should_append_msg {
            self.active_chat.messages.append_messages(vec![msg]);
        }
        return should_append_msg;
    }

    pub fn top_reached(&mut self, new_messages: Vec<ui_adapter::Message>, has_more: bool) {
        // get earliest message in displayed_messages and set to ChatBehavior.view_behavior -> ScrollUp
        // set on_scroll_up depending on if there are more messages
        // perhaps set on_scroll_down
        // append to self.messages
        todo!()
    }

    pub fn bottom_reached(&mut self, new_messages: Vec<ui_adapter::Message>, has_more: bool) {
        // get most recent message in displayed_messages and set to ChatBehavior.view_behavior -> ScrollDown
        // set on_scroll_down depending on if there are more messages
        // perhaps set on_scroll_up
        // prepend to self.messages
        todo!()
    }
}
