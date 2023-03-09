use dioxus::prelude::*;
use std::path::PathBuf;

// these help filling in Details
pub static CARGO_VERSION: &str = env!("CARGO_PKG_VERSION");
pub static RUSTC_VERSION: &str = env!("RUSTC_VERSION");

#[cfg(target_os = "macos")]
pub static FILE_EXT: &str = "dylib";
#[cfg(target_os = "linux")]
pub static FILE_EXT: &str = "so";
#[cfg(target_os = "windows")]
pub static FILE_EXT: &str = "dll";

/// This must be implemented by an extension
pub trait Extension {
    fn details(&self) -> Details;
    fn stylesheet(&self) -> String;
    fn render<'a>(&self, cx: &'a ScopeState) -> Element<'a>;
}

/// after defining a struct (say as a static variable) and implementing the Extension trait, call this: `export_extension!(<name of struct variable>); `
/// This should provide the needed library interface.
#[macro_export]
macro_rules! export_extension {
    ($a:expr) => {
        #[doc(hidden)]
        #[no_mangle]
        pub extern "C" fn details() -> Details {
            $a.details()
        }

        #[doc(hidden)]
        #[no_mangle]
        pub extern "C" fn stylesheet() -> String {
            $a.stylesheet()
        }

        #[doc(hidden)]
        #[no_mangle]
        pub extern "C" fn render<'a>(cx: &'a ScopeState) -> Element<'a> {
            $a.render(cx)
        }
    };
}

// this might belong in Uplink
/// This is used by Uplink to interact with shared libraries
pub struct UplinkExtension {
    lib: libloading::Library,
    details: Details,
    stylesheet: String,
    is_enabled: bool,
}

impl UplinkExtension {
    pub fn new(location: PathBuf) -> Result<Self, libloading::Error> {
        unsafe {
            let lib = libloading::Library::new(location)?;
            let details = lib.get::<unsafe extern "C" fn() -> Details>(b"details\0")?();
            let stylesheet = lib.get::<unsafe extern "C" fn() -> String>(b"stylesheet\0")?();
            Ok(Self {
                lib,
                details,
                stylesheet,
                is_enabled: false,
            })
        }
    }
    pub fn details(&self) -> &Details {
        &self.details
    }

    pub fn stylesheet(&self) -> &str {
        &self.stylesheet
    }

    // todo: can an element be converted to an HTML string and have the string be returned instead?
    pub fn render<'a>(&self, cx: &'a ScopeState) -> Element<'a> {
        unsafe {
            let res = self
                .lib
                .get::<unsafe extern "C" fn(cx: &'a ScopeState) -> Element<'a>>(b"render\0");
            match res {
                Ok(f) => f(cx),
                Err(_) => None,
            }
        }
    }

    pub fn enabled(&self) -> bool {
        self.is_enabled
    }

    pub fn set_enabled(&mut self, b: bool) {
        self.is_enabled = b;
    }
}

#[repr(C)]
pub struct Details {
    // Location(s) the extension should be rendered.
    pub location: Location,
    // The type of extension being rendered.
    pub ext_type: Type,
    // Additional information about the extension
    pub meta: Meta,
    pub cargo_version: &'static str,
    pub rustc_version: &'static str,
}

// Represents where the extensions main render method should execute.
// Note that some extension types will NOT render in some locations.
#[repr(C)]
pub enum Location {
    Chatbar,
    Replies,
    Sidebar,
    Settings,
}

// Right now IconLaunched is the only supported render mode. This will evolve over time.
#[repr(C)]
pub enum Type {
    IconLaunched,
    // InlineUI,
    // Headless,
}

// Contains details about the extension for humans.
#[repr(C)]
#[derive(Clone)]
pub struct Meta {
    pub name: &'static str,
    pub author: &'static str,
    pub pretty_name: &'static str,
    pub description: &'static str,
}
