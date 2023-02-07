use dioxus::prelude::Element;
use either::Either;

#[cfg(target_os = "macos")]
static FILE_EXT: &str = "dylib";
#[cfg(target_os = "linux")]
static FILE_EXT: &str = "so";
#[cfg(target_os = "windows")]
static FILE_EXT: &str = "dll";

// Represents where the extensions main render mthod should execute.
// Note that some extension types will NOT render in some locations.
pub enum Location {
    Chatbar,
    Replies,
    Sidebar,
    Settings,
}

// Right now IconLaunched is the only supported render mode. This will evolve over time.
pub enum Type {
    IconLaunched,
    // InlineUI,
    // Headless,
}

// Contains details about the extension for humans.
pub struct Meta {
    pub name: &'static str,
    pub author: &'static str,
    pub pretty_name: &'static str,
    pub description: &'static str,
}

pub static CORE_VERSION: &str = env!("CARGO_PKG_VERSION");
pub static RUSTC_VERSION: &str = env!("RUSTC_VERSION");

pub struct Manifest {
    pub rustc_version: &'static str,
    pub core_version: &'static str,

    // Location(s) the extension should be rendered.
    pub location: Either<Location, Vec<Location>>,
    // The type of extension being rendered.
    pub ext_type: crate::Type,
    // Additional information about the extension
    pub meta: Meta,
}

pub enum Error {
    Render { message: String },
    Generic { message: String },
}

// Extension Interface
pub trait Extension {
    fn about(&self) -> Manifest;

    fn stylesheet(&self) -> String;

    fn render(&self) -> Result<Element, crate::Error>;
}

impl Default for Manifest {
    fn default() -> Self {
        Self {
            rustc_version: "0.0.0",
            core_version: "0.0.0",
            location: either::Left(Location::Chatbar),
            ext_type: crate::Type::IconLaunched,
            meta: Meta {
                name: "basic",
                author: "Unknown",
                pretty_name: "Basic Extension",
                description: "",
            },
        }
    }
}
