pub mod elements;
pub mod components;
pub mod layout;
pub mod icons;

const VARS: &'static str = include_str!("./style.css");
const TW: &'static str = include_str!("./tailwind.css");


/// Loads the stylesheet to string.
pub fn get_styles(styles: &'static str) -> String {
    format!("{}{}", crate::VARS, styles);
    format!("{}{}", crate::TW, styles)
}

/// Loads the script to string.
pub fn get_script(script: &'static str, uuid: &String) -> String {
    // The replace is needed because you can't have hyphens in javascript declarations.
    script.replace("DIUU", &uuid).replace("SAFE_UUID", &uuid.clone().replace("-", "_"))
}