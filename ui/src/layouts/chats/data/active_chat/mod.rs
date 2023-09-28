use std::collections::{HashMap, VecDeque};

use chrono::{DateTime, Utc};
use common::{
    state::{self, Identity, State},
    warp_runner::ui_adapter,
};
use kit::components::indicator::Platform;
use uuid::Uuid;
use warp::raygun::ConversationType;

use crate::layouts::chats::data::ScrollBehavior;

use super::{MsgView, PartialMessage};

mod messages;
mod metadata;
pub use messages::*;
pub use metadata::*;

#[derive(Debug, Default, Clone)]
pub struct ActiveChat {
    pub metadata: Metadata,
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
    pub fn has_more_messages(&self) -> bool {
        matches!(self.chat_behavior.on_scroll_top, ScrollBehavior::FetchMore)
    }

    pub fn init_message_times(&mut self) {
        self.message_times.clear();
        for m in self.messages.iter() {
            self.message_times.insert(m.inner.id(), m.inner.date());
        }
    }

    pub fn set(&mut self, other: Self) {
        let _ = std::mem::replace(self, other);
    }

    pub fn get_message_time(&self, msg_id: &Uuid) -> Option<DateTime<Utc>> {
        self.message_times.get(msg_id).cloned()
    }

    pub fn add_message_to_view(&mut self, msg_id: Uuid) {
        match self.get_message_time(&msg_id) {
            Some(date) => {
                self.displayed_messages.insert(PartialMessage {
                    message_id: msg_id,
                    date,
                });
            }
            None => {
                log::warn!("tried to add message to view but datetime lookup failed");
            }
        }
    }

    pub fn remove_message_from_view(&mut self, msg_id: Uuid) {
        self.displayed_messages.remove(msg_id);
    }

    pub fn clear_message_view(&mut self) {
        self.displayed_messages.clear();
    }

    pub fn top_reached(&mut self, new_messages: Vec<ui_adapter::Message>, has_more: bool) {
        // get earliest message in displayed_messages and set to ChatBehavior.view_behavior -> ScrollUp
        // set on_scroll_up depending on if there are more messages
        // perhaps set on_scroll_down
        // append to self.messages
    }

    pub fn bottom_reached(&mut self, new_messages: Vec<ui_adapter::Message>, has_more: bool) {
        // get most recent message in displayed_messages and set to ChatBehavior.view_behavior -> ScrollDown
        // set on_scroll_down depending on if there are more messages
        // perhaps set on_scroll_up
        // prepend to self.messages
    }
}
