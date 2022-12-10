pub mod elements;
pub mod components;
pub mod layout;
pub mod icons;

const VARS: &str = include_str!("./style.css");

/// Loads the stylesheet to string.
pub fn get_styles(styles: &str) -> String {
    format!("{}{}", crate::VARS, styles)
}

/// Loads the script to string.
pub fn get_script(script: &'static str, uuid: &str) -> String {
    // The replace is needed because you can't have hyphens in javascript declarations.
    script.replace("DIUU", uuid).replace("SAFE_UUID", &uuid.replace('-', "_"))
}