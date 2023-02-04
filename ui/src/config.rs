use serde::{Deserialize, Serialize};

use std::fs;

use crate::STATIC_ARGS;

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
    #[serde(default)]
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
            ..Self::default()
        }
    }

    pub fn load() -> Self {
        // Load the config from the specified path
        match fs::read_to_string(&STATIC_ARGS.config_path) {
            Ok(contents) => {
                // Parse the config from the file contents using serde
                match serde_json::from_str(&contents) {
                    Ok(config) => config,
                    Err(_) => Self::new(),
                }
            }
            Err(_) => Self::new(),
        }
    }

    pub fn load_or_default() -> Self {
        // Try to load the config from the specified path
        match fs::read_to_string(&STATIC_ARGS.config_path) {
            Ok(contents) => {
                // Parse the config from the file contents using serde
                match serde_json::from_str(&contents) {
                    Ok(config) => config,
                    Err(_) => Self::new(),
                }
            }
            Err(_) => Self::new(),
        }
    }

    pub fn save(&self) -> Result<(), std::io::Error> {
        let config_json = serde_json::to_string(self)?;
        fs::write(&STATIC_ARGS.config_path, config_json)?;
        Ok(())
    }
}
