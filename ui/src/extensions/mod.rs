use extensions::*;
use libloading::Library;
use std::{collections::HashMap, ffi::OsStr, io, rc::Rc};

struct ExtensionRegistrar {
    extensions: HashMap<String, ExtensionProxy>,
    lib: Rc<Library>,
}

impl ExtensionRegistrar {
    fn new(lib: Rc<Library>) -> ExtensionRegistrar {
        ExtensionRegistrar {
            lib,
            extensions: HashMap::default(),
        }
    }
}

impl extensions::ExtensionRegistrar for ExtensionRegistrar {
    fn register(&mut self, name: &str, extension: Box<dyn Extension>) {
        let proxy = ExtensionProxy {
            extension,
            _lib: Rc::clone(&self.lib),
        };
        self.extensions.insert(name.to_string(), proxy);
    }
}

#[derive(Default)]
pub struct AvailableExtensions {
    pub extensions: HashMap<String, ExtensionProxy>,
    pub libraries: Vec<Rc<Library>>,
}

impl AvailableExtensions {
    pub fn new() -> AvailableExtensions {
        AvailableExtensions::default()
    }

    /// # Safety
    ///
    /// An extension **must** be implemented using the
    /// [`extensions::export_extension!()`] macro. Trying manually implement
    /// a plugin without going through that macro will result in undefined
    /// behaviour.
    pub unsafe fn load<P: AsRef<OsStr>>(&mut self, library_path: P) -> io::Result<()> {
        // load the library into memory
        let library = Rc::new(Library::new(library_path).unwrap());

        let extension_info = library.get::<*mut Core>(b"extension_entry").unwrap().read();

        // version checks to prevent accidental ABI incompatibilities
        if extension_info.rustc_version != extensions::RUSTC_VERSION
            || extension_info.core_version != extensions::CORE_VERSION
        {
            return Err(io::Error::new(io::ErrorKind::Other, "Version mismatch"));
        }

        let mut registrar = ExtensionRegistrar::new(Rc::clone(&library));

        (extension_info.register)(&mut registrar);

        // add all loaded extensions to the extensions map
        self.extensions.extend(registrar.extensions);
        // and make sure AvailableExtensions keeps a reference to the library
        self.libraries.push(library);

        Ok(())
    }
}
