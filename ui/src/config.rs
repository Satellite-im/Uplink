use serde::{Deserialize, Serialize};

use std::fs;

use crate::UPLINK_PATH;

/// A struct that represents the configuration of the application.
#[derive(Debug, Default, Deserialize, Serialize)]
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
}

#[derive(Debug, Default, Deserialize, Serialize)]
pub struct General {
    #[serde(default)]
    pub theme: String,
    #[serde(default)]
    pub show_splash: bool,
    #[serde(default)]
    pub enable_overlay: bool,
}

#[derive(Debug, Default, Deserialize, Serialize)]
pub struct Privacy {
    #[serde(default)]
    pub satellite_sync_nodes: bool,
    #[serde(default)]
    pub safer_file_scanning: bool,
}

#[derive(Debug, Default, Deserialize, Serialize)]
pub struct AudioVideo {
    #[serde(default)]
    pub noise_suppression: bool,
    #[serde(default)]
    pub call_timer: bool,
}

#[derive(Debug, Default, Deserialize, Serialize)]
pub struct Extensions {
    #[serde(default)]
    pub enable: bool,
}

#[derive(Debug, Default, Deserialize, Serialize)]
pub struct Developer {
    #[serde(default)]
    pub developer_mode: bool,
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
        let config_path = UPLINK_PATH.join("Config.json");
        // Load the config from the specified path
        match fs::read_to_string(config_path) {
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
        let config_path = UPLINK_PATH.join("Config.json");

        // Try to load the config from the specified path
        match fs::read_to_string(config_path) {
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

    fn save(&self) -> Result<(), std::io::Error> {
        let config_json = serde_json::to_string(self)?;
        let config_path = UPLINK_PATH.join("Config.json");

        fs::write(config_path, config_json)?;
        Ok(())
    }
}

impl Configuration {
    pub fn set_theme(&mut self, theme_name: String) {
        self.general.theme = theme_name;
        let _ = self.save();
    }

    pub fn set_overlay(&mut self, overlay: bool) {
        self.general.enable_overlay = overlay;
        let _ = self.save();
    }

    pub fn set_developer_mode(&mut self, developer_mode: bool) {
        self.developer.developer_mode = developer_mode;
        let _ = self.save();
    }
}
