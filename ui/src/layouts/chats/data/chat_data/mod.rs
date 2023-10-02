use std::collections::{HashMap, VecDeque};

use chrono::{DateTime, Utc};
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
    pub fn add_message_to_view(&mut self, conv_id: Uuid, message_id: Uuid) {
        if conv_id != self.active_chat.id() {
            return;
        }
        self.active_chat.messages.add_message_to_view(message_id);

        if self
            .active_chat
            .messages
            .all
            .front()
            .map(|x| x.inner.id() == message_id)
            .unwrap_or_default()
        {
            self.scroll_up(conv_id);
        } else {
            self.scroll_down(conv_id);
        }
    }

    pub fn get_top_of_view(&self, conv_id: Uuid) -> Option<PartialMessage> {
        if self.active_chat.id() != conv_id {
            return None;
        }

        self.active_chat.messages.get_earliest_displayed()
    }

    pub fn get_bottom_of_view(&self, conv_id: Uuid) -> Option<PartialMessage> {
        if self.active_chat.id() != conv_id {
            return None;
        }

        self.active_chat.messages.get_latest_displayed()
    }

    // call this first to fetch the messages
    pub fn get_chat_behavior(&self, id: Uuid) -> ChatBehavior {
        self.chat_behaviors.get(&id).cloned().unwrap_or_default()
    }

    pub fn insert_messages(&mut self, conv_id: Uuid, messages: Vec<ui_adapter::Message>) {
        if self.active_chat.id() != conv_id {
            return;
        }

        self.active_chat.messages.insert_messages(messages);
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
            self.active_chat.messages.insert_messages(vec![msg]);
        }
        return should_append_msg;
    }

    pub fn remove_message_from_view(&mut self, conv_id: Uuid, message_id: Uuid) {
        if conv_id != self.active_chat.id() {
            return;
        }
        self.active_chat
            .messages
            .remove_message_from_view(message_id);
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
        } else {
            self.active_chat = ActiveChat::default();
            log::error!("failed to set active chat to id: {chat_id}");
        }
    }

    pub fn scrolled(&mut self, conv_id: Uuid) {
        if self.active_chat.id() == conv_id {
            self.active_chat.scrolled_once = true;
        }
    }

    pub fn set_chat_behavior(&mut self, id: Uuid, behavior: ChatBehavior) {
        self.chat_behaviors.insert(id, behavior);
    }
}

impl ChatData {
    fn scroll_up(&mut self, conv_id: Uuid) {
        if let Some(behavior) = self.chat_behaviors.get_mut(&conv_id) {
            if let Some(scroll_top) = self.active_chat.messages.get_earliest_displayed() {
                behavior.view_init.scroll_to = ScrollTo::ScrollUp {
                    view_top: scroll_top.message_id,
                };
                behavior.view_init.msg_time.replace(scroll_top.date);
            }
        }
    }

    fn scroll_down(&mut self, conv_id: Uuid) {
        if let Some(behavior) = self.chat_behaviors.get_mut(&conv_id) {
            if let Some(scroll_bottom) = self.active_chat.messages.get_latest_displayed() {
                behavior.view_init.scroll_to = ScrollTo::ScrollDown {
                    view_bottom: scroll_bottom.message_id,
                };
                behavior.view_init.msg_time.replace(scroll_bottom.date);
            }
        }
    }
}
