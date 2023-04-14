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
    // displays above the app icon on the desktop
    #[serde(skip)]
    pub badge: u32,
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
            badge: 0,
        }
    }

    // Adds notification(s) to the specified kind.
    pub fn increment(
        &mut self,
        config: &Configuration,
        kind: NotificationKind,
        count: u32,
        increment_badge: bool,
    ) {
        match kind {
            NotificationKind::FriendRequest => {
                if config.notifications.friends_notifications {
                    self.friends = self.friends.saturating_add(count);
                    if increment_badge {
                        self.badge = self.badge.saturating_add(count);
                    }
                }
            }
            NotificationKind::Message => {
                if config.notifications.messages_notifications {
                    self.messages = self.messages.saturating_add(count);
                    if increment_badge {
                        self.badge = self.badge.saturating_add(count);
                    }
                }
            }
            NotificationKind::Settings => {
                if config.notifications.settings_notifications {
                    self.settings = self.settings.saturating_add(count);
                    if increment_badge {
                        self.badge = self.badge.saturating_add(count);
                    }
                }
            }
        };

        if increment_badge {
            let _ = set_badge(self.badge);
        }
    }

    // Removes notification(s) from the specified kind.
    // Prevent underflow using saturating_sub()
    pub fn decrement(&mut self, kind: NotificationKind, count: u32) {
        match kind {
            NotificationKind::FriendRequest => {
                self.friends = self.friends.saturating_sub(count);
                self.badge = self.badge.saturating_sub(count);
            }
            NotificationKind::Message => {
                self.messages = self.messages.saturating_sub(count);
                self.badge = self.badge.saturating_sub(count);
            }
            NotificationKind::Settings => {
                self.settings = self.settings.saturating_sub(count);
                self.badge = self.badge.saturating_sub(count);
            }
        };

        // Update the badge any time notifications are removed.
        let _ = set_badge(self.badge);
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
    pub fn clear_kind(&mut self, kind: NotificationKind) {
        match kind {
            NotificationKind::FriendRequest => {
                self.badge = self.badge.saturating_sub(self.friends);
                self.friends = 0;
            }
            NotificationKind::Message => {
                self.badge = self.badge.saturating_sub(self.messages);
                self.messages = 0;
            }
            NotificationKind::Settings => {
                self.badge = self.badge.saturating_sub(self.settings);
                self.settings = 0;
            }
        };
        // Update the badge with new possible totals.
        let _ = set_badge(self.badge);
    }

    // Clears all notifications.
    pub fn clear_all(&mut self) {
        self.friends = 0;
        self.messages = 0;
        self.settings = 0;

        self.badge = 0;
        let _ = set_badge(self.badge);
    }

    pub fn clear_badge(&mut self) {
        self.badge = 0;
        let _ = set_badge(self.badge);
    }
}
