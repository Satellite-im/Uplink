use serde::{Deserialize, Serialize};

use crate::{
    config::Configuration,
    utils::{notifications::set_badge, sounds::Sounds},
};

// This kind is used to determine which notification kind to add to. It can also be used for querying specific notification counts.
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
            // Represents the total notification count for all friend events.
            friends: 0,
            // Represents the total notification count for all message events. Including all conversations and groups.
            messages: 0,
            // Represents total notification count for all settings events. E.g. updates, issues, etc.
            settings: 0,
        }
    }

    // This method is used for calculating the badge count for the app tray icon.
    pub fn total(&self) -> u32 {
        // Since this is read only, we can just load the config here.
        let config = Configuration::load_or_default();

        let mut total = 0;

        // Only count notifications that are enabled in the config.
        if config.notifications.friends_notifications {
            total += self.friends;
        }
        if config.notifications.messages_notifications {
            total += self.messages;
        }
        if config.notifications.settings_notifications {
            total += self.settings;
        }

        total
    }

    // Adds notification(s) to the specified kind.
    pub fn increment(&mut self, kind: NotificaitonKind, count: u32) {
        match kind {
            NotificaitonKind::FriendRequest => self.friends += count,
            NotificaitonKind::Message => self.messages += count,
            NotificaitonKind::Settings => self.settings += count,
        };

        // Update the badge any time notifications are added.
        let _ = set_badge(self.total());

        // Plays the notification sound.
        let config = Configuration::load_or_default();
        if config.notifications.enabled {
            crate::utils::sounds::Play(Sounds::Notification);
        }
    }

    // Removes notification(s) from the specified kind.
    pub fn decrement(&mut self, kind: NotificaitonKind, count: u32) {
        match kind {
            NotificaitonKind::FriendRequest => {
                // Prevent underflow.
                if count > self.friends {
                    self.friends = 0
                } else {
                    self.friends -= count
                }
            }
            NotificaitonKind::Message => {
                // Prevent underflow.
                if count > self.messages {
                    self.messages = 0
                } else {
                    self.messages -= count
                }
            }
            NotificaitonKind::Settings => {
                // Prevent underflow.
                if count > self.settings {
                    self.settings = 0
                } else {
                    self.settings -= count
                }
            }
        };

        // Update the badge any time notifications are removed.
        let _ = set_badge(self.total());
    }

    // Sets a notification count for the specified kind.
    pub fn set(&mut self, kind: NotificaitonKind, count: u32) {
        match kind {
            NotificaitonKind::FriendRequest => self.friends = count,
            NotificaitonKind::Message => self.messages = count,
            NotificaitonKind::Settings => self.settings = count,
        };

        // Update the badge with new possible totals.
        let _ = set_badge(self.total());
    }

    // Returns the total count for a given notification kind.
    pub fn get(&self, kind: NotificaitonKind) -> u32 {
        match kind {
            NotificaitonKind::FriendRequest => self.friends,
            NotificaitonKind::Message => self.messages,
            NotificaitonKind::Settings => self.settings,
        }
    }

    // Clears all notifications for the specified kind.
    pub fn clear_kind(&mut self, kind: NotificaitonKind) {
        match kind {
            NotificaitonKind::FriendRequest => self.friends = 0,
            NotificaitonKind::Message => self.messages = 0,
            NotificaitonKind::Settings => self.settings = 0,
        };
        // Upadte the badge with new possible totals.
        let _ = set_badge(self.total());
    }

    // Clears all notifications.
    pub fn clear_all(&mut self) {
        self.friends = 0;
        self.messages = 0;
        self.settings = 0;

        // Clear the badge.
        let _ = set_badge(self.total());
    }
}
