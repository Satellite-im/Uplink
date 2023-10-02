use chrono::{DateTime, Utc};
use common::warp_runner::ui_adapter;
use std::collections::{HashMap, VecDeque};
use uuid::Uuid;

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
        for msg in m.drain(..) {
            message_times.insert(msg.inner.id(), msg.inner.date());
            messages.push_back(msg);
        }

        Self {
            all: messages,
            displayed: VecDeque::new(),
            times: message_times,
        }
    }

    pub fn insert_messages(&mut self, m: Vec<ui_adapter::Message>) {
        if m.is_empty() {
            return;
        }

        if self.all.is_empty() {
            return self.append_messages(m);
        }

        // latest last
        if m.last().unwrap().inner.date() <= self.all.front().unwrap().inner.date() {
            return self.prepend_messages(m);
        }

        // earliest first
        if m.first().unwrap().inner.date() >= self.all.back().unwrap().inner.date() {
            return self.append_messages(m);
        }

        log::error!("invalid insert");
    }

    pub fn get_earliest_displayed(&self) -> Option<PartialMessage> {
        self.displayed
            .front()
            .and_then(|id| match self.times.get(id) {
                Some(date) => Some(PartialMessage {
                    message_id: *id,
                    date: *date,
                }),
                None => None,
            })
    }

    pub fn get_latest_displayed(&self) -> Option<PartialMessage> {
        self.displayed
            .back()
            .and_then(|id| match self.times.get(id) {
                Some(date) => Some(PartialMessage {
                    message_id: *id,
                    date: *date,
                }),
                None => None,
            })
    }

    pub fn add_message_to_view(&mut self, message_id: Uuid) {
        let date = match self.times.get(&message_id).cloned() {
            Some(time) => time,
            None => return,
        };
        if self.displayed.is_empty() {
            self.displayed.push_back(message_id);
        } else if self
            .displayed
            .front()
            .and_then(|x| self.times.get(x))
            .map(|front| front >= &date)
            .unwrap_or(false)
        {
            // earliest in front
            self.displayed.push_front(message_id);
        } else if self
            .displayed
            .back()
            .and_then(|x| self.times.get(x))
            .map(|back| back <= &date)
            .unwrap_or(false)
        {
            // latest in back
            self.displayed.push_back(message_id);
        } else {
            log::error!(
                "invalid insert in to active_chat.dispalyed: {:?}",
                message_id
            );
            let mut new_displayed = VecDeque::new();
            let mut to_insert = Some(message_id);
            for id in self.displayed.drain(..) {
                let id_time = self.times.get(&id).expect("time should exist");
                let should_insert = to_insert
                    .as_ref()
                    .and_then(|id| self.times.get(id))
                    .map(|new_time| new_time >= id_time)
                    .unwrap_or(false);

                if should_insert {
                    let new_id = to_insert.take().unwrap();
                    new_displayed.push_back(new_id);
                    log::info!("fixed insert insert for id: {:?}", message_id);
                }

                new_displayed.push_back(id);
            }
            self.displayed = new_displayed;
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
            log::error!("failed to remove message from view. fixing with retain()");
            self.displayed.retain(|x| x != &message_id);
        }
    }
}

impl Messages {
    fn append_messages(&mut self, mut m: Vec<ui_adapter::Message>) {
        for msg in m.drain(..) {
            // check for duplicates. really only needed for the first element the Vec
            if !self.times.contains_key(&msg.inner.id()) {
                self.times.insert(msg.inner.id(), msg.inner.date());
                self.all.push_back(msg);
            }
        }
    }

    fn prepend_messages(&mut self, mut m: Vec<ui_adapter::Message>) {
        let mut new_all = VecDeque::new();
        for msg in m.drain(..) {
            // check for duplicates. really only needed for the first element the Vec
            if !self.times.contains_key(&msg.inner.id()) {
                self.times.insert(msg.inner.id(), msg.inner.date());
                new_all.push_back(msg);
            }
        }

        new_all.append(&mut self.all);
        self.all = new_all;
    }
}
