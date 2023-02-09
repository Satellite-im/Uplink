use dioxus::prelude::*;
use libloading::Library;
use std::{collections::HashMap, ffi::OsStr, fs, path::PathBuf, rc::Rc};

use warp::logging::tracing::log;

pub static CORE_VERSION: &str = env!("CARGO_PKG_VERSION");
pub static RUSTC_VERSION: &str = env!("RUSTC_VERSION");

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

#[derive(Default)]
// Contains details about the extension for humans.
pub struct Meta {
    pub name: &'static str,
    pub author: &'static str,
    pub pretty_name: &'static str,
    pub description: &'static str,
}

pub trait ExtensionRegistrar {
    fn register(&mut self, name: &str, function: Box<dyn Extension>);
}

pub struct Core {
    pub rustc_version: &'static str,
    pub core_version: &'static str,
    pub register: unsafe extern "C" fn(&mut dyn ExtensionRegistrar),
}

pub struct Details {
    // Location(s) the extension should be rendered.
    pub location: Location,
    // The type of extension being rendered.
    pub ext_type: Type,
    // Additional information about the extension
    pub meta: Meta,
}

impl Default for Details {
    fn default() -> Self {
        Self {
            location: Location::Chatbar,
            ext_type: Type::IconLaunched,
            meta: Meta {
                name: "basic",
                author: "Unknown",
                pretty_name: "Basic Extension",
                description: "",
            },
        }
    }
}

pub enum Error {
    Render { message: String },
    Generic { message: String },
}

// Basic extension interface with the minimum required information.
pub trait Extension {
    fn get(&self) -> Details;

    fn stylesheet(&self) -> String;

    fn render(&self, cx: Scope) -> Element;
}

#[derive(Default)]
pub struct Librarian {}

impl Librarian {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn locate(&mut self, path: PathBuf) -> &Self {
        log::debug!("Locating extensions");

        // TODO: Search the extensions folder for files. Load them into self
        let _ = fs::create_dir_all(&path);

        let paths = fs::read_dir(&path).expect("Directory is empty");

        for entry in paths {
            let path = entry.unwrap().path();
            if path.extension().unwrap_or_default() == FILE_EXT {}
        }
        self
    }
}

#[macro_export]
macro_rules! export_extension {
    ($register:expr) => {
        #[doc(hidden)]
        #[no_mangle]
        pub static extension_entry: $crate::Core = $crate::Core {
            rustc_version: $crate::RUSTC_VERSION,
            core_version: $crate::CORE_VERSION,
            register: $register,
        };
    };
}

/// A proxy object which wraps an [`Extension`] and makes sure it can't outlive
/// the library it came from.
pub struct ExtensionProxy {
    extension: Box<dyn Extension>,
    _lib: Rc<Library>,
}

impl Extension for ExtensionProxy {
    fn get(&self) -> Details {
        self.extension.get()
    }

    fn stylesheet(&self) -> String {
        self.extension.stylesheet()
    }

    fn render(&self, cx: Scope) -> Element {
        self.extension.render(cx)
    }
}
