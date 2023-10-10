use chrono::{DateTime, Utc};
use common::warp_runner::ui_adapter;
use std::collections::{HashMap, VecDeque};
use uuid::Uuid;

use crate::layouts::chats::data::DEFAULT_MESSAGES_TO_TAKE;

use super::PartialMessage;

#[derive(Debug, Default, Clone)]
pub struct Messages {
    // messages should be sorted by time in increasing order. earliest first, latest last.
    pub all: VecDeque<ui_adapter::Message>,
    pub displayed: VecDeque<Uuid>,
    // used for displayed_messages
    pub times: HashMap<Uuid, DateTime<Utc>>,
}

impl Messages {
    pub fn new(mut m: VecDeque<ui_adapter::Message>) -> Self {
        let mut message_times = HashMap::new();
        let mut messages = VecDeque::new();
        let displayed = VecDeque::new();
        for msg in m.drain(..) {
            message_times.insert(msg.inner.id(), msg.inner.date());
            messages.push_back(msg);
        }

        Self {
            all: messages,
            displayed,
            times: message_times,
        }
    }

    pub fn reset(&mut self) {
        let len = self.all.len();
        for msg in self
            .all
            .drain(0..len.saturating_sub(DEFAULT_MESSAGES_TO_TAKE))
        {
            self.times.remove(&msg.inner.id());
        }
        self.displayed.clear();
    }

    pub fn insert_messages(&mut self, m: Vec<ui_adapter::Message>) {
        if m.is_empty() {
            return;
        }

        let (is_valid, _) =
            m.iter().fold(
                (true, None),
                |(is_valid, prev_value), msg| match prev_value {
                    Some(prev_date) => (
                        is_valid && msg.inner.date() >= prev_date,
                        Some(msg.inner.date()),
                    ),
                    None => (is_valid, Some(msg.inner.date())),
                },
            );
        if !is_valid {
            log::error!("invalid data passed to insert_messages");
            return;
        }

        if self.all.is_empty() {
            log::debug!("appending messages");
            return self.append_messages(m);
        }

        // latest last
        if m.last().unwrap().inner.date() <= self.all.front().unwrap().inner.date() {
            log::debug!("prepending messages");
            return self.prepend_messages(m);
        }

        // earliest first
        if m.first().unwrap().inner.date() >= self.all.back().unwrap().inner.date() {
            log::debug!("appending messages");
            return self.append_messages(m);
        }

        log::error!("invalid insert");
    }

    pub fn get_earliest_displayed(&self) -> Option<PartialMessage> {
        self.displayed.front().and_then(|id| {
            self.times.get(id).map(|date| PartialMessage {
                message_id: *id,
                date: *date,
            })
        })
    }

    pub fn get_latest_displayed(&self) -> Option<PartialMessage> {
        self.displayed.back().and_then(|id| {
            self.times.get(id).map(|date| PartialMessage {
                message_id: *id,
                date: *date,
            })
        })
    }

    pub fn add_message_to_view(&mut self, message_id: Uuid) {
        let date = match self.times.get(&message_id).cloned() {
            Some(time) => time,
            None => {
                log::error!("tried to add message to view but time lookup failed");
                return;
            }
        };

        // if self.displayed.contains(&message_id) {
        //     log::warn!("attempted to insert duplicate message");
        //     return;
        // }

        // these variables allow for debugging
        let front = self.displayed.front().and_then(|x| self.times.get(x));
        let back = self.displayed.back().and_then(|x| self.times.get(x));

        if self.displayed.is_empty() {
            self.displayed.push_back(message_id);
        } else if front.map(|front| front > &date).unwrap_or(false) {
            // earliest in front
            self.displayed.push_front(message_id);
        } else if back.map(|back| back < &date).unwrap_or(false) {
            // latest in back
            self.displayed.push_back(message_id);
        } else {
            // this isn't always an error
            // log::warn!(
            //     "invalid insert in to active_chat.dispalyed: {:?}",
            //     message_id
            // );
        }
    }

    pub fn remove_message_from_view(&mut self, message_id: Uuid) {
        if self
            .displayed
            .front()
            .map(|x| x == &message_id)
            .unwrap_or(false)
        {
            self.displayed.pop_front();
        } else if self
            .displayed
            .back()
            .map(|x| x == &message_id)
            .unwrap_or(false)
        {
            self.displayed.pop_back();
        } else {
            // during initialization this triggers when removing a nonexistent item.
            // log::warn!("failed to remove message from view. fixing with retain()");
            // self.displayed.retain(|x| x != &message_id);
        }
    }

    pub fn top(&self) -> Option<Uuid> {
        self.all.front().map(|x| x.inner.id())
    }

    pub fn bottom(&self) -> Option<Uuid> {
        self.all.back().map(|x| x.inner.id())
    }
}

impl Messages {
    fn append_messages(&mut self, mut m: Vec<ui_adapter::Message>) {
        m.retain(|x| !self.times.contains_key(&x.inner.id()));
        for msg in m.iter() {
            self.times.insert(msg.inner.id(), msg.inner.date());
        }
        let mut new_msgs = VecDeque::from_iter(m.drain(..));
        self.all.append(&mut new_msgs);

        let extra = self.all.len().saturating_sub(DEFAULT_MESSAGES_TO_TAKE);
        if extra > 0 {
            for _ in 0..extra {
                if let Some(msg) = self.all.pop_front() {
                    self.times.remove(&msg.inner.id());
                }
            }
        }
    }

    fn prepend_messages(&mut self, mut m: Vec<ui_adapter::Message>) {
        m.retain(|x| !self.times.contains_key(&x.inner.id()));
        for msg in m.iter() {
            self.times.insert(msg.inner.id(), msg.inner.date());
        }
        let mut new_all = VecDeque::from_iter(m.drain(..));
        new_all.append(&mut self.all);
        self.all = new_all;

        let extra = self.all.len().saturating_sub(DEFAULT_MESSAGES_TO_TAKE);
        let end = self.all.len();
        let start = end - extra;
        for _ in start..end {
            if let Some(msg) = self.all.pop_back() {
                self.times.remove(&msg.inner.id());
            }
        }
    }
}
