use std::collections::VecDeque;

use uuid::Uuid;

use super::PartialMessage;

// the back of the VecDeque is the top of the view.
// used to track which messages are visible and determine
// which message needs to be scrolled to.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct MsgView {
    items: VecDeque<PartialMessage>,
}

impl MsgView {
    pub fn new() -> Self {
        Self {
            items: VecDeque::new(),
        }
    }

    pub fn clear(&mut self) {
        self.items.clear();
    }

    pub fn insert(&mut self, val: PartialMessage) {
        if self.items.is_empty() {
            self.items.push_back(val);
        } else if self.items.front().map(|x| &val >= x).unwrap_or(false) {
            // messages occuring later in time have a greater value
            self.items.push_front(val);
        } else if self.items.back().map(|x| &val <= x).unwrap_or(false) {
            self.items.push_back(val);
        } else {
            println!("invalid insert: {:?}", val);
        }
    }

    pub fn remove(&mut self, id: Uuid) {
        if self
            .items
            .front()
            .map(|x| x.message_id == id)
            .unwrap_or(false)
        {
            self.items.pop_front();
        } else if self
            .items
            .back()
            .map(|x| x.message_id == id)
            .unwrap_or(false)
        {
            self.items.pop_back();
        } else {
            // println!("invalid remove: {:?}", val);
        }
    }

    pub fn get_back(&self) -> Option<PartialMessage> {
        self.items.back().cloned()
    }

    pub fn get_front(&self) -> Option<PartialMessage> {
        self.items.front().cloned()
    }

    pub fn get_idx(&self, idx: usize) -> Option<PartialMessage> {
        self.items.get(idx).cloned()
    }
}
