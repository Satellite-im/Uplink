use serde::{Deserialize, Serialize};

pub enum NotificaitonKind {
    FriendRequest,
    Message,
    Settings,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Notifications {
    pub friends: u32, // For notifications about new friends, friend requests and related CTAs.
    pub messages: u32, // For notifications about new messages, mentions.
    pub settings: u32, // For notifications about updates, issues and more.
}

impl Notifications {
    pub fn new() -> Self {
        // By default we'll say there are no notifications.
        Self {
            friends: 0,
            messages: 0,
            settings: 0,
        }
    }

    pub fn total(&self) -> u32 {
        let mut total = 0;

        // TODO: This should be configurable by the user so they are only notified about the things they want to be notified about.
        total += self.friends;
        total += self.messages;
        total += self.settings;

        total
    }

    pub fn add(&mut self, kind: NotificaitonKind, count: u32) {
        match kind {
            NotificaitonKind::FriendRequest => self.friends += count,
            NotificaitonKind::Message => self.messages += count,
            NotificaitonKind::Settings => self.settings += count,
        }
    }

    pub fn remove(&mut self, kind: NotificaitonKind, count: u32) {
        match kind {
            NotificaitonKind::FriendRequest => self.friends -= count,
            NotificaitonKind::Message => self.messages -= count,
            NotificaitonKind::Settings => self.settings -= count,
        }
    }

    pub fn set(&mut self, kind: NotificaitonKind, count: u32) {
        match kind {
            NotificaitonKind::FriendRequest => self.friends = count,
            NotificaitonKind::Message => self.messages = count,
            NotificaitonKind::Settings => self.settings = count,
        }
    }

    pub fn clear_kind(&mut self, kind: NotificaitonKind) {
        match kind {
            NotificaitonKind::FriendRequest => self.friends = 0,
            NotificaitonKind::Message => self.messages = 0,
            NotificaitonKind::Settings => self.settings = 0,
        }
    }

    pub fn clear_all(&mut self) {
        self.friends = 0;
        self.messages = 0;
        self.settings = 0;
    }
}
