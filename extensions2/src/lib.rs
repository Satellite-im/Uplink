use dioxus::prelude::*;
use std::ffi::CString;

#[cfg(target_os = "macos")]
pub static FILE_EXT: &str = "dylib";
#[cfg(target_os = "linux")]
pub static FILE_EXT: &str = "so";
#[cfg(target_os = "windows")]
pub static FILE_EXT: &str = "dll";

/// This is used by Uplink to interact with shared libraries
pub struct Extension {
    lib: libloading::Library,
}

impl Extension {
    pub fn new(location: &str) -> Result<Self, libloading::Error> {
        unsafe {
            let lib = libloading::Library::new(location)?;
            Ok(Self { lib })
        }
    }
    pub fn details(&self) -> Result<Details, Box<dyn std::error::Error>> {
        let res = unsafe {
            self.lib
                .get::<unsafe extern "C" fn() -> Details>(b"details\0")?()
        };
        Ok(res)
    }

    pub fn stylesheet(&self) -> Result<String, Box<dyn std::error::Error>> {
        let res = unsafe {
            self.lib
                .get::<unsafe extern "C" fn() -> CString>(b"stylesheet\0")?()
        };
        Ok(res.to_string_lossy().to_string())
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

// Basic extension interface with the minimum required information.
pub trait Extension2 {
    fn details(&self) -> Details;

    fn stylesheet(&self) -> String;

    fn render<'a>(&self, cx: &'a ScopeState) -> Element<'a>;
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
pub struct Meta {
    pub name: &'static str,
    pub author: &'static str,
    pub pretty_name: &'static str,
    pub description: &'static str,
}
