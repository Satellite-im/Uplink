use std::collections::{HashMap, VecDeque};

use chrono::{DateTime, Utc};
use common::{
    state::chats2::{ChatBehavior, ScrollBehavior},
    warp_runner::ui_adapter,
};
use uuid::Uuid;

use super::{MsgView, PartialMessage};

#[derive(Debug, Default)]
pub struct ActiveChat {
    pub conversation_id: Uuid,
    pub messages: VecDeque<ui_adapter::Message>,
    pub chat_behavior: ChatBehavior,

    pub displayed_messages: MsgView,
    // used for displayed_messages
    pub message_times: HashMap<Uuid, DateTime<Utc>>,
}

// uses to initialize active chat
pub struct ActiveChatArgs {
    pub conversation_id: Uuid,
    pub messages: Vec<ui_adapter::Message>,
    pub chat_behavior: ChatBehavior,
}

impl ActiveChat {
    pub fn new(args: ActiveChatArgs) -> Self {
        let mut message_times = HashMap::new();
        for msg in args.messages.iter() {
            message_times.insert(msg.inner.id(), msg.inner.date());
        }
        Self {
            conversation_id: args.conversation_id,
            messages: VecDeque::from(args.messages),
            chat_behavior: args.chat_behavior,
            displayed_messages: MsgView::default(),
            message_times,
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
}
