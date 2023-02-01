use serde::{Deserialize, Serialize};

use crate::config::Configuration as Config;

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Configuration {
    #[serde(default)]
    pub config: Config,
    // We should allow for custom config options here in the future to support extension developers.
}

impl Configuration {
    pub fn new() -> Self {
        Self {
            config: Config::load_or_default(),
        }
    }
    pub fn set_theme(&mut self, theme_name: String) {
        self.config.general.theme = theme_name;
        let _ = self.config.save();
    }

    pub fn set_overlay(&mut self, overlay: bool) {
        self.config.general.enable_overlay = overlay;
        let _ = self.config.save();
    }

    pub fn set_developer_mode(&mut self, developer_mode: bool) {
        self.config.developer.developer_mode = developer_mode;
        let _ = self.config.save();
    }

    pub fn set_friends_notifications(&mut self, friends_notifications: bool) {
        self.config.notifications.friends_notifications = friends_notifications;
        let _ = self.config.save();
    }

    pub fn set_messages_notifications(&mut self, messages_notifications: bool) {
        self.config.notifications.messages_notifications = messages_notifications;
        let _ = self.config.save();
    }

    pub fn set_settings_notifications(&mut self, settings_notifications: bool) {
        self.config.notifications.settings_notifications = settings_notifications;
        let _ = self.config.save();
    }
}
