use dioxus::prelude::{Component, Element};
use either::Either;
use libloading::{Library, Symbol};
use std::{ffi::OsStr, fs};
use warp::logging::tracing::log;

type BoxedExtension = unsafe fn() -> Box<Extension>;

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

pub enum Error {
    Render { message: String },
    Generic { message: String },
}

pub struct Extension {
    pub rustc_version: &'static str,
    pub core_version: &'static str,

    // Location(s) the extension should be rendered.
    pub location: Either<Location, Vec<Location>>,
    // The type of extension being rendered.
    pub ext_type: Type,
    // Additional information about the extension
    pub meta: Meta,
}

impl Default for Extension {
    fn default() -> Self {
        Self {
            rustc_version: "0.0.0",
            core_version: "0.0.0",
            location: either::Left(Location::Chatbar),
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

impl Extension {
    pub fn load<P: AsRef<OsStr>>(filename: P) -> Result<Self, crate::Error> {
        unsafe {
            let lib = Library::new(filename).unwrap();
            let extension: Symbol<BoxedExtension> = lib.get(b"ret_extension").unwrap();

            Ok(Self { ..*extension() })
        }
    }
}

// Extension Interface
pub trait BaseExtension {
    fn about(&self) -> Extension;

    fn stylesheet(&self) -> String;

    fn render(&self) -> Result<Element, crate::Error>;
}

pub struct Librarian {
    extensions: Vec<Extension>,
}

impl Librarian {
    pub fn new() {
        // TODO: Create the proper directory structure needed to store the extensions
    }

    pub fn locate(&mut self) -> &Self {
        // TODO: Search the extensions folder for files. Load them into self
        let extensions_path = &crate::STATIC_ARGS.extensions_path;
        let paths = fs::read_dir(extensions_path).expect("Directory is empty");
        let _ = fs::create_dir_all(extensions_path);

        let mut extensions: Vec<Extension> = vec![];

        for entry in paths {
            let path = entry.unwrap().path();
            if path.extension().unwrap_or_default() == FILE_EXT {
                let result = Extension::load(&path);
                match result {
                    Ok(extension) => {
                        log::info!("Extension loaded {:?}", &extension.meta.name);
                        extensions.push(extension);
                    }
                    Err(_) => {
                        log::error!("Failed to load extension {:?}", &path);
                    }
                }
            }
        }

        self.extensions = extensions;

        self
    }

    pub fn remove(extension: Extension) -> Result<(), crate::Error> {
        // TODO: Remove the extension from disk.
        println!("Extension: {:?}", extension.meta.pretty_name);
        Ok(())
    }
}
