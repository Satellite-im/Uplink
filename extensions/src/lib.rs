use dioxus::prelude::*;
use libloading::Library;
use std::{fmt, rc::Rc};

pub static CORE_VERSION: &str = env!("CARGO_PKG_VERSION");
pub static RUSTC_VERSION: &str = env!("RUSTC_VERSION");

#[cfg(target_os = "macos")]
pub static FILE_EXT: &str = "dylib";
#[cfg(target_os = "linux")]
pub static FILE_EXT: &str = "so";
#[cfg(target_os = "windows")]
pub static FILE_EXT: &str = "dll";

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
    pub rustc_version: String,
    pub core_version: String,
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
    fn details(&self) -> Details;

    fn stylesheet(&self) -> String;

    fn render<'a>(&self, cx: &'a ScopeState) -> Element<'a>;
}

#[macro_export]
macro_rules! export_extension {
    ($register:expr) => {
        #[doc(hidden)]
        #[no_mangle]
        pub extern "C" fn extension_entry() -> *mut $crate::Core {
            let core = $crate::Core {
                rustc_version: $crate::RUSTC_VERSION.into(),
                core_version: $crate::CORE_VERSION.into(),
                register: $register,
            };
            Box::into_raw(Box::new(core)) as _
        }
    };
}

/// A proxy object which wraps an [`Extension`] and makes sure it can't outlive
/// the library it came from.
pub struct ExtensionProxy {
    pub extension: Box<dyn Extension>,
    pub enabled: bool,
    pub _lib: Rc<Library>,
}

impl fmt::Display for ExtensionProxy {
    // This trait requires `fmt` with this exact signature.
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        // Write strictly the first element into the supplied output
        // stream: `f`. Returns `fmt::Result` which indicates whether the
        // operation succeeded or failed. Note that `write!` uses syntax which
        // is very similar to `println!`.
        write!(f, ".")
    }
}

impl Extension for ExtensionProxy {
    fn details(&self) -> Details {
        self.extension.details()
    }

    fn stylesheet(&self) -> String {
        self.extension.stylesheet()
    }

    fn render<'a>(&self, cx: &'a ScopeState) -> Element<'a> {
        self.extension.render(cx)
    }
}
