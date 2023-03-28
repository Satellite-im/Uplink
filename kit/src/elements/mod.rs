use derive_more::Display;

pub mod button;
pub mod checkbox;
pub mod file;
pub mod folder;
pub mod input;
pub mod label;
pub mod multiline;
pub mod select;
pub mod slider;
pub mod switch;
pub mod textarea;
pub mod tooltip;

#[derive(Clone, PartialEq, Eq, Copy, Display)]
/// Decides the look and feel of a button, also modifies some functionality.
pub enum Appearance {
    #[display(fmt = "default")]
    Default,

    #[display(fmt = "primary")]
    Primary,

    #[display(fmt = "secondary")]
    Secondary,

    #[display(fmt = "secondary-less")]
    SecondaryLess,

    #[display(fmt = "success")]
    Success,

    #[display(fmt = "danger")]
    Danger,

    #[display(fmt = "disabled")]
    Disabled,

    #[display(fmt = "transparent")]
    Transparent,
}
