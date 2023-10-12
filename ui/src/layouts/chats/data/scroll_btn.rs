use std::collections::HashMap;

use uuid::Uuid;

#[derive(Default)]
pub struct ScrollBtn {
    should_show: HashMap<Uuid, bool>,
}

impl ScrollBtn {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn set(&mut self, chat_id: Uuid) {
        self.should_show.insert(chat_id, true);
    }

    pub fn clear(&mut self, chat_id: Uuid) {
        self.should_show.remove(&chat_id);
    }

    pub fn get(&self, chat_id: Uuid) -> bool {
        self.should_show.get(&chat_id).cloned().unwrap_or_default()
    }
}
