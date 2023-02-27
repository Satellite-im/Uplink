use serde::{Deserialize, Serialize};

use crate::notifications::set_badge;

use super::configuration::Configuration;

// This kind is used to determine which notification kind to add to. It can also be used for querying specific notification counts.
pub enum NotificationKind {
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
    pub fn total(&self, config: &Configuration) -> u32 {
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
    pub fn increment(&mut self, config: &Configuration, kind: NotificationKind, count: u32) {
        match kind {
            NotificationKind::FriendRequest => self.friends += count,
            NotificationKind::Message => self.messages += count,
            NotificationKind::Settings => self.settings += count,
        };

        // Update the badge any time notifications are added.
        let _ = set_badge(self.total(config));
    }

    // Removes notification(s) from the specified kind.
    // Prevent underflow using saturating_sub()
    pub fn decrement(&mut self, config: &Configuration, kind: NotificationKind, count: u32) {
        match kind {
            NotificationKind::FriendRequest => {
                self.friends = self.friends.saturating_sub(count);
            }
            NotificationKind::Message => {
                self.messages = self.messages.saturating_sub(count);
            }
            NotificationKind::Settings => {
                self.settings = self.settings.saturating_sub(count);
            }
        };

        // Update the badge any time notifications are removed.
        let _ = set_badge(self.total(config));
    }

    // Sets a notification count for the specified kind.
    pub fn set(&mut self, config: &Configuration, kind: NotificationKind, count: u32) {
        match kind {
            NotificationKind::FriendRequest => self.friends = count,
            NotificationKind::Message => self.messages = count,
            NotificationKind::Settings => self.settings = count,
        };

        // Update the badge with new possible totals.
        let _ = set_badge(self.total(config));
    }

    // Returns the total count for a given notification kind.
    pub fn get(&self, kind: NotificationKind) -> u32 {
        match kind {
            NotificationKind::FriendRequest => self.friends,
            NotificationKind::Message => self.messages,
            NotificationKind::Settings => self.settings,
        }
    }

    // Clears all notifications for the specified kind.
    pub fn clear_kind(&mut self, config: &Configuration, kind: NotificationKind) {
        match kind {
            NotificationKind::FriendRequest => self.friends = 0,
            NotificationKind::Message => self.messages = 0,
            NotificationKind::Settings => self.settings = 0,
        };
        // Update the badge with new possible totals.
        let _ = set_badge(self.total(config));
    }

    // Clears all notifications.
    pub fn clear_all(&mut self, config: &Configuration) {
        self.friends = 0;
        self.messages = 0;
        self.settings = 0;

        // Clear the badge.
        let _ = set_badge(self.total(config));
    }
}
