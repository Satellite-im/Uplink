use std::mem::transmute;
use std::path::PathBuf;

use objc::{
    class, msg_send,
    runtime::{Class, Object},
    sel, sel_impl,
};
use objc_foundation::{INSArray, INSString, NSArray, NSDictionary, NSObject, NSString};
use objc_id::{Id, Owned};
use warp::error::Error;

#[link(name = "AppKit", kind = "framework")]
extern "C" {
    static NSPasteboardURLReadingFileURLsOnlyKey: &'static Object;
}

pub struct MacOSClipboard {
    pasteboard: Id<Object>,
}

impl MacOSClipboard {
    pub fn new() -> Result<Self, Error> {
        Self::get_pasteboard().map(|pasteboard| Self { pasteboard })
    }

    pub fn get_files_path_from_clipboard(&self) -> Result<Vec<PathBuf>, Error> {
        let nsurl_array_option = self.get_nsurl_array();
        let results = match nsurl_array_option {
            Some(nsurl_array) => self.extract_paths_from_nsurl_array(nsurl_array),
            None => Vec::new(),
        };
        Ok(results.into_iter().map(PathBuf::from).collect())
    }
}

impl MacOSClipboard {
    fn get_pasteboard() -> Result<Id<Object>, Error> {
        let ns_pasteboard = class!(NSPasteboard);
        let ptr: *mut Object = unsafe { msg_send![ns_pasteboard, generalPasteboard] };
        if ptr.is_null() {
            log::error!("Error to generate MacOS native PasteBoard.");
            Err(Error::Other)
        } else {
            Ok(unsafe { Id::from_ptr(ptr) })
        }
    }

    fn get_nsurl_array(&self) -> Option<Id<NSArray<NSObject>>> {
        let classes = self.get_classes();
        let options = self.get_options();

        self.read_objects_for_classes(&classes, &options)
    }

    fn get_classes(&self) -> Id<NSArray<NSObject, Owned>> {
        let nsurl_class: Id<NSObject> = {
            let cls: Id<Class> = unsafe { Id::from_ptr(transmute(Class::get("NSURL"))) };
            unsafe { transmute(cls) }
        };
        NSArray::from_vec(vec![nsurl_class])
    }

    fn get_options(&self) -> Id<NSDictionary<NSObject, NSObject>> {
        let ns_dict = class!(NSDictionary);
        let ns_number = class!(NSNumber);
        unsafe {
            let obj: Id<NSObject> =
                Id::from_ptr(msg_send![ns_number, numberWithBool: objc::runtime::YES]);
            Id::from_ptr(
                msg_send![ns_dict, dictionaryWithObject: &*obj forKey: NSPasteboardURLReadingFileURLsOnlyKey],
            )
        }
    }

    fn read_objects_for_classes(
        &self,
        classes: &Id<NSArray<NSObject, Owned>>,
        options: &Id<NSDictionary<NSObject, NSObject>>,
    ) -> Option<Id<NSArray<NSObject>>> {
        unsafe {
            let obj: *mut NSArray<NSObject> =
                msg_send![self.pasteboard, readObjectsForClasses:&**classes options:&**options];
            if obj.is_null() {
                None
            } else {
                Some(Id::from_ptr(obj))
            }
        }
    }

    fn extract_paths_from_nsurl_array(&self, nsurl_array: Id<NSArray<NSObject>>) -> Vec<String> {
        nsurl_array
            .to_vec()
            .into_iter()
            .filter_map(|obj| self.get_path_if_file_url(obj))
            .collect()
    }

    fn get_path_if_file_url(&self, obj: &NSObject) -> Option<String> {
        let is_file: bool = unsafe { msg_send![obj, isFileURL] };
        if is_file {
            let s: &NSString = unsafe { msg_send![obj, path] };
            Some(s.as_str().to_owned())
        } else {
            None
        }
    }
}
