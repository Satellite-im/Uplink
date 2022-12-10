use std::fmt;

pub mod button;
pub mod tooltip;
pub mod switch;
pub mod select;
pub mod input;
pub mod label;
pub mod multiline;
pub mod slider;
pub mod folder;
pub mod file;

#[derive(Clone, PartialEq, Eq, Copy)]
/// Decides the look and feel of a button, also modifies some functionality.
pub enum Appearance {
    Default,
    Primary,
    Secondary,
    Success,
    Danger,
    Disabled,
    Transparent,
}

impl fmt::Display for Appearance {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Appearance::Default => write!(f, "default"),
            Appearance::Primary => write!(f, "primary"),
            Appearance::Secondary => write!(f, "secondary"),
            Appearance::Success => write!(f, "success"),
            Appearance::Danger => write!(f, "danger"),
            Appearance::Disabled => write!(f, "disabled"),
            Appearance::Transparent => write!(f, "transparent"),
        }
    }
}