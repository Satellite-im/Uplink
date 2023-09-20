use std::collections::{HashMap, VecDeque};

use chrono::{DateTime, Utc};
use common::{
    state::chats2::{ChatBehavior, ScrollBehavior},
    warp_runner::ui_adapter,
};
use uuid::Uuid;
use warp::raygun;

use super::SortedList;

#[derive(Debug, Default)]
pub struct ActiveChat {
    pub conversation_id: Option<Uuid>,
    pub messages: VecDeque<ui_adapter::Message>,
    pub chat_behavior: ChatBehavior,

    pub displayed_messages: SortedList,
    pub message_stream: Option<raygun::MessageStream>,
    // may want a message stream to simplify fetching more messages when the user scrolls up...maybe another stream for scrolling down...

    // used for displayed_messages
    pub message_times: HashMap<Uuid, DateTime<Utc>>,
}

impl ActiveChat {
    pub fn has_more_messages(&self) -> bool {
        matches!(self.chat_behavior.on_scroll_top, ScrollBehavior::FetchMore)
    }

    pub fn find_message_times(&mut self) {
        self.message_times.clear();
        for m in self.messages.iter() {
            self.message_times.insert(m.inner.id(), m.inner.date());
        }
    }
}
