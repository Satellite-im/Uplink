use dioxus::prelude::*;
use std::{ffi::CString, path::PathBuf};

#[cfg(target_os = "macos")]
pub static FILE_EXT: &str = "dylib";
#[cfg(target_os = "linux")]
pub static FILE_EXT: &str = "so";
#[cfg(target_os = "windows")]
pub static FILE_EXT: &str = "dll";

/// This must be implemented by an extension
pub trait Extension {
    fn details(&self) -> Details;
    fn stylesheet(&self) -> CString;
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
        pub extern "C" fn stylesheet() -> CString {
            $a.stylesheet()
        }

        #[doc(hidden)]
        #[no_mangle]
        pub extern "C" fn render<'a>(cx: &'a ScopeState) -> Element<'a> {
            $a.render(cx)
        }
    };
}

/// This is used by Uplink to interact with shared libraries
pub struct UplinkExtension {
    lib: libloading::Library,
    details: Details,
    stylesheet: String,
}

impl UplinkExtension {
    pub fn new(location: PathBuf) -> Result<Self, libloading::Error> {
        unsafe {
            let lib = libloading::Library::new(location)?;
            let details = lib.get::<unsafe extern "C" fn() -> Details>(b"details\0")?();
            let stylesheet = lib.get::<unsafe extern "C" fn() -> CString>(b"stylesheet\0")?();
            Ok(Self {
                lib,
                details,
                stylesheet: stylesheet.to_string_lossy().to_string(),
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
}

#[repr(C)]
pub struct Details {
    // Location(s) the extension should be rendered.
    pub location: Location,
    // The type of extension being rendered.
    pub ext_type: Type,
    // Additional information about the extension
    pub meta: Meta,
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
