use std::fs;
use std::io::{Error, Write};

use crate::DEFAULT_PATH;
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Config {
    pub general: General,
    pub privacy: Privacy,
    pub audiovideo: AudioVideo,
    pub extensions: Extensions,
    pub developer: Developer,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Privacy {
    pub satellite_sync_nodes: bool,
    pub safer_file_scanning: bool,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct General {
    pub theme: String,
    pub show_splash: bool,
}

#[derive(Debug, Serialize, Deserialize, Copy, Clone)]
pub struct AudioVideo {
    pub noise_suppression: bool,
    pub call_timer: bool,
}

#[derive(Debug, Serialize, Deserialize, Copy, Clone)]
pub struct Extensions {
    pub enable: bool,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Developer {
    pub developer_mode: bool,
    pub cache_dir: String,
}

// Implementation to create, load and save the config
impl Config {
    fn default() -> Self {
        Self {
            general: General {
                theme: String::from("default"),
                show_splash: true,
            },
            privacy: Privacy {
                satellite_sync_nodes: true,
                safer_file_scanning: true,
            },
            extensions: Extensions { enable: true },
            audiovideo: AudioVideo {
                noise_suppression: false,
                call_timer: false,
            },
            developer: Developer {
                developer_mode: false,
                cache_dir: String::from(".warp"),
            },
        }
    }

    pub fn new_file() {
        let toml = toml::to_string(&Config::default()).unwrap();
        if fs::metadata(DEFAULT_PATH.read().join("Config.toml")).is_err() {
            fs::write(DEFAULT_PATH.read().join("Config.toml"), toml).unwrap();
        }
    }

    pub fn load_config_or_default() -> Config {
        let binding = DEFAULT_PATH.read().join("Config.toml");
        let config_location = binding.to_str().unwrap();
        let contents = match fs::read_to_string(config_location) {
            // If successful return the files text as `contents`.
            // `c` is a local variable.
            Ok(c) => c,
            // Handle the `error` case.
            Err(_) => {
                // Write `msg` to `stderr`.
                eprintln!("Could not read file `{}`", config_location);
                // Exit the program with exit code `1`.
                String::from("")
            }
        };
        // Use a `match` block to return the
        // file `contents` as a `Config struct: Ok(c)`
        // or handle any `errors: Err(_)`.
        let config: Config = match toml::from_str(&contents) {
            // If successful, return data as `Data` struct.
            // `c` is a local variable.
            Ok(c) => c,
            // Handle the `error` case.
            Err(_) => {
                // Write `msg` to `stderr`.
                eprintln!("Unable to load data from `{}`", config_location);
                // Exit the program with exit code `1`.
                Config::default()
            }
        };
        config
    }

    pub fn save(&self) -> Result<(), Error> {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .open(DEFAULT_PATH.read().join("Config.toml"))?;
        self.save_to_writer(&mut file)
    }

    pub fn save_to_writer<W: Write>(&self, writer: &mut W) -> Result<(), Error> {
        let default = match toml::to_string(&Config::load_config_or_default()) {
            Ok(d) => d,
            Err(_) => String::from(""),
        };
        let config_data = match toml::to_string(&self) {
            Ok(d) => d,
            Err(_) => default,
        };
        writer.write_all(config_data.as_bytes())?;
        writer.flush()?;
        Ok(())
    }
}
