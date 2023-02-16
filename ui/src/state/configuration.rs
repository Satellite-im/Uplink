use serde::{Deserialize, Serialize};

use super::action::ConfigAction;

/// A struct that represents the configuration of the application.
#[derive(Debug, Default, Deserialize, Serialize, Clone)]
pub struct Configuration {
    /// General configuration options.
    #[serde(default)]
    pub general: General,

    /// Privacy-related configuration options.
    #[serde(default)]
    pub privacy: Privacy,

    /// Audio and video-related configuration options.
    #[serde(default)]
    pub audiovideo: AudioVideo,

    /// Extension-related configuration options.
    #[serde(default)]
    pub extensions: Extensions,

    /// Developer-related configuration options.
    #[serde(default)]
    pub developer: Developer,

    /// Notification-related configuration options.
    #[serde(default)]
    pub notifications: Notifications,
}

#[derive(Debug, Default, Deserialize, Serialize, Clone)]
pub struct General {
    #[serde(default)]
    pub theme: String,
    #[serde(default)]
    pub show_splash: bool,
    #[serde(default)]
    pub enable_overlay: bool,
}

#[derive(Debug, Default, Deserialize, Serialize, Copy, Clone)]
pub struct Privacy {
    #[serde(default)]
    pub satellite_sync_nodes: bool,
    #[serde(default)]
    pub safer_file_scanning: bool,
}

#[derive(Debug, Default, Deserialize, Serialize, Copy, Clone)]
pub struct AudioVideo {
    #[serde(default)]
    pub noise_suppression: bool,
    #[serde(default)]
    pub call_timer: bool,
    #[serde(default)]
    pub interface_sounds: bool,
    #[serde(default = "bool_true")]
    pub message_sounds: bool,
    #[serde(default = "bool_true")]
    pub media_sounds: bool,
}

#[derive(Debug, Default, Deserialize, Serialize, Copy, Clone)]
pub struct Extensions {
    #[serde(default)]
    pub enable: bool,
}

#[derive(Debug, Default, Deserialize, Serialize, Copy, Clone)]
pub struct Developer {
    #[serde(default)]
    pub developer_mode: bool,
}

fn bool_true() -> bool {
    true
}

// We may want to give the user the ability to pick and choose which notifications they want to see.
// This is a good place to start.
#[derive(Debug, Default, Deserialize, Serialize, Copy, Clone)]
pub struct Notifications {
    #[serde(default = "bool_true")]
    pub enabled: bool,
    #[serde(default)]
    pub show_app_icon: bool,
    #[serde(default = "bool_true")]
    pub friends_notifications: bool,
    #[serde(default = "bool_true")]
    pub messages_notifications: bool,
    // By default we leave this one off.
    #[serde(default)]
    pub settings_notifications: bool,
}

impl Configuration {
    pub fn new() -> Self {
        // Create a default configuration here
        // For example:
        Self {
            developer: Developer {
                ..Developer::default()
            },
            audiovideo: AudioVideo {
                message_sounds: true,
                media_sounds: true,
                ..AudioVideo::default()
            },
            notifications: Notifications {
                enabled: true,
                friends_notifications: true,
                messages_notifications: true,
                ..Notifications::default()
            },
            ..Self::default()
        }
    }
}

impl Configuration {
    pub fn handle_action(&mut self, action: ConfigAction) {
        match action {
            ConfigAction::NotificationsEnabled(enabled) => self.notifications.enabled = enabled,
            ConfigAction::Theme(theme_name) => self.general.theme = theme_name,
            ConfigAction::OverlayEnabled(overlay) => self.general.enable_overlay = overlay,
            ConfigAction::DevModeEnabled(flag) => self.developer.developer_mode = flag,
            ConfigAction::InterfaceSoundsEnabled(flag) => self.audiovideo.interface_sounds = flag,
            ConfigAction::MediaSoundsEnabled(flag) => self.audiovideo.media_sounds = flag,
            ConfigAction::MessageSoundsEnabled(flag) => self.audiovideo.message_sounds = flag,
            ConfigAction::FriendsNotificationsEnabled(flag) => {
                self.notifications.friends_notifications = flag
            }
            ConfigAction::MessagesNotificationsEnabled(flag) => {
                self.notifications.messages_notifications = flag
            }
            ConfigAction::SettingsNotificationsEnabled(flag) => {
                self.notifications.settings_notifications = flag
            }
        }
    }
}
