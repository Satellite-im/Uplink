use serde::{Deserialize, Serialize};

use std::fs;
use std::path::Path;

#[derive(Debug, Default, Deserialize, Serialize)]
struct Config {
    #[serde(default)]
    general: General,
    #[serde(default)]
    privacy: Privacy,
    #[serde(default)]
    audiovideo: AudioVideo,
    #[serde(default)]
    extensions: Extensions,
    #[serde(default)]
    developer: Developer,
}

#[derive(Debug, Default, Deserialize, Serialize)]
struct General {
    #[serde(default)]
    theme: String,
    #[serde(default)]
    show_splash: bool,
}

#[derive(Debug, Default, Deserialize, Serialize)]
struct Privacy {
    #[serde(default)]
    satellite_sync_nodes: bool,
    #[serde(default)]
    safer_file_scanning: bool,
}

#[derive(Debug, Default, Deserialize, Serialize)]
struct AudioVideo {
    #[serde(default)]
    noise_suppression: bool,
    #[serde(default)]
    call_timer: bool,
}

#[derive(Debug, Default, Deserialize, Serialize)]
struct Extensions {
    #[serde(default)]
    enable: bool,
}

#[derive(Debug, Default, Deserialize, Serialize)]
struct Developer {
    #[serde(default)]
    developer_mode: bool,
    #[serde(default)]
    cache_dir: String,
}

impl Config {
    pub fn set_theme(&mut self, theme_name: String) {
        self.general.theme = theme_name;
    }
}

impl Config {
    fn new() -> Self {
        // Create a default configuration here
        // For example:
        Self::default()
    }

    fn load<P: AsRef<Path>>(path: P) -> Self {
        // Load the config from the specified path
        match fs::read_to_string(path) {
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

    fn save<P: AsRef<Path>>(&self, path: P) -> Result<(), std::io::Error> {
        let config_json = serde_json::to_string(self)?;
        fs::write(path, config_json)?;
        Ok(())
    }
}
