use serde::{Deserialize, Serialize};
use warp::logging::tracing::log;

use crate::STATIC_ARGS;

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
    pub dyslexia_support: bool,
    #[serde(default)]
    pub theme: String,
    #[serde(default)]
    pub font: Option<String>,
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

#[derive(Debug, Deserialize, Serialize, Copy, Clone, Eq, PartialEq)]
pub struct AudioVideo {
    #[serde(default = "bool_true")]
    pub echo_cancellation: bool,
    #[serde(default)]
    pub call_timer: bool,
    #[serde(default)]
    pub interface_sounds: bool,
    #[serde(default = "bool_true")]
    pub message_sounds: bool,
    #[serde(default = "bool_true")]
    pub media_sounds: bool,
}

impl Default for AudioVideo {
    fn default() -> Self {
        Self {
            echo_cancellation: false,
            call_timer: false,
            interface_sounds: false,
            message_sounds: true,
            media_sounds: true,
        }
    }
}

#[derive(Debug, Default, Deserialize, Serialize, Copy, Clone)]
pub struct Extensions {
    #[serde(default)]
    pub enable: bool,
    #[serde(default = "bool_true")]
    pub enable_automatically: bool,
}

#[derive(Debug, Default, Deserialize, Serialize, Copy, Clone)]
pub struct Developer {
    #[serde(default)]
    pub developer_mode: bool,
    #[serde(default)]
    pub experimental_features: bool,
}

fn bool_true() -> bool {
    true
}

// We may want to give the user the ability to pick and choose which notifications they want to see.
// This is a good place to start.
#[derive(Debug, Deserialize, Serialize, Copy, Clone, Eq, PartialEq)]
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

impl Default for Notifications {
    fn default() -> Self {
        Self {
            enabled: true,
            show_app_icon: false,
            friends_notifications: true,
            messages_notifications: true,
            settings_notifications: false,
        }
    }
}

impl Configuration {
    pub fn new() -> Self {
        // Create a default configuration here
        // For example:
        Self::default()
    }
}

impl Configuration {
    pub fn load_or_default() -> Self {
        if let Ok(b) = std::fs::read(&STATIC_ARGS.login_config_path) {
            if let Ok(n) = serde_json::from_slice(&b) {
                return n;
            }
        }

        Self::default()
    }

    pub fn mutate(&mut self, action: ConfigAction) {
        let old_audiovideo = self.audiovideo;
        match action {
            ConfigAction::SetNotificationsEnabled(enabled) => self.notifications.enabled = enabled,
            ConfigAction::SetTheme(theme_name) => self.general.theme = theme_name,
            ConfigAction::SetOverlayEnabled(overlay) => self.general.enable_overlay = overlay,
            ConfigAction::SetDyslexicEnabled(flag) => self.general.dyslexia_support = flag,
            ConfigAction::SetDevModeEnabled(flag) => self.developer.developer_mode = flag,
            ConfigAction::SetExperimentalFeaturesEnabled(flag) => {
                self.developer.experimental_features = flag
            }
            ConfigAction::SetInterfaceSoundsEnabled(flag) => {
                self.audiovideo.interface_sounds = flag
            }
            ConfigAction::SetMediaSoundsEnabled(flag) => self.audiovideo.media_sounds = flag,
            ConfigAction::SetMessageSoundsEnabled(flag) => self.audiovideo.message_sounds = flag,
            ConfigAction::SetFriendsNotificationsEnabled(flag) => {
                self.notifications.friends_notifications = flag
            }
            ConfigAction::SetMessagesNotificationsEnabled(flag) => {
                self.notifications.messages_notifications = flag
            }
            ConfigAction::SetSettingsNotificationsEnabled(flag) => {
                self.notifications.settings_notifications = flag
            }
            ConfigAction::SetAutoEnableExtensions(flag) => {
                self.extensions.enable_automatically = flag
            }
            ConfigAction::SetEchoCancellation(flag) => self.audiovideo.echo_cancellation = flag,
        }

        if self.audiovideo != old_audiovideo {
            let contents = match serde_json::to_string(&self.audiovideo) {
                Ok(c) => c,
                Err(e) => {
                    log::error!("failed to serialize audiovideo: {e}");
                    return;
                }
            };
            if let Err(e) = std::fs::write(&STATIC_ARGS.login_config_path, contents) {
                log::error!("failed to save login_config: {e}");
            }
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn deserialize_notifications_config() {
        let empty_str = String::from("{}");
        let serde_notifications: Notifications =
            serde_json::from_str(&empty_str).expect("failed to deserialize empty string");
        let default_notifications = Notifications::default();

        assert_eq!(default_notifications, serde_notifications);
    }

    #[test]
    fn deserialize_audiovideo_config() {
        let empty_str = String::from("{}");
        let serde_audiovideo: AudioVideo =
            serde_json::from_str(&empty_str).expect("failed to deserialize empty string");
        let default_audiovideo = AudioVideo::default();

        assert_eq!(default_audiovideo, serde_audiovideo);
    }
}
