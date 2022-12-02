pub use dioxus_heroicons::outline::Shape as Icon;
pub use dioxus_heroicons::Icon as IconElement;

pub mod button;
pub use button::button as UiButton;

pub mod tooltip;
pub use tooltip::tooltip as UiTooltip;

pub mod switch;
pub use switch::switch as UiSwitch;

const VARS: &'static str = include_str!("./style.css");

/// Loads the stylesheet to string.
pub fn get_styles(styles: &'static str) -> String {
    format!("{}{}", crate::VARS, styles)
}

/// Loads the script to string.
pub fn get_script(script: &'static str, uuid: &String) -> String {
    // The replace is needed because you can't have hyphens in javascript declarations.
    script.replace("DIUU", &uuid).replace("SAFE_UUID", &uuid.clone().replace("-", "_"))
}