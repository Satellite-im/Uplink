use components::indicator::{Platform, Status};

pub mod components;
pub mod elements;
pub mod layout;

pub const STYLE: &str = include_str!("./compiled_styles.css");

pub struct User {
    pub username: String,
    pub photo: String,
    pub status: Status,
    pub platform: Platform,
}

/// Loads the script to string.
pub fn get_script(script: &'static str, uuid: &str) -> String {
    // The replace is needed because you can't have hyphens in javascript declarations.
    script
        .replace("DIUU", uuid)
        .replace("SAFE_UUID", &uuid.replace('-', "_"))
}
