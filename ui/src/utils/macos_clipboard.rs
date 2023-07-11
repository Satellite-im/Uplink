#![cfg(macos)]
/*!
This file provide simple means to operate with MacOS clipboard.
*/

use std::mem::transmute;
use std::path::PathBuf;

use objc::sel;
use objc::{
    class, msg_send,
    runtime::{Class, Object},
    sel_impl,
};
use objc_foundation::{INSArray, INSString, NSArray, NSDictionary, NSObject, NSString};
use objc_id::{Id, Owned};
use warp::error::Error;

pub struct MacOSClipboard {
    pasteboard: Id<Object>,
}

// required to bring NSPasteboard into the path of the class-resolver
#[link(name = "AppKit", kind = "framework")]
extern "C" {
    // NSString
    static NSPasteboardURLReadingFileURLsOnlyKey: &'static Object;
}

impl MacOSClipboard {
    pub fn new() -> Result<MacOSClipboard, Error> {
        let ns_pasteboard = class!(NSPasteboard);
        let pasteboard: *mut Object = unsafe { msg_send![ns_pasteboard, generalPasteboard] };
        if pasteboard.is_null() {
            log::error!("Error to generate MacOS native PasteBoard.");
            return Err(Error::Other);
        }
        let pasteboard: Id<Object> = unsafe { Id::from_ptr(pasteboard) };
        Ok(MacOSClipboard { pasteboard })
    }

    pub fn read(&self) -> Result<Vec<PathBuf>, Error> {
        let ns_dict = class!(NSDictionary);
        let ns_number = class!(NSNumber);
        let options: Id<NSDictionary<NSObject, NSObject>> = unsafe {
            let obj: Id<NSObject> =
                Id::from_ptr(msg_send![ns_number, numberWithBool: objc::runtime::YES]);
            Id::from_ptr(
                msg_send![ns_dict, dictionaryWithObject: &*obj forKey: NSPasteboardURLReadingFileURLsOnlyKey],
            )
        };

        let nsurl_class: Id<NSObject> = {
            let cls: Id<Class> = unsafe { Id::from_ptr(class("NSURL")) };
            unsafe { transmute(cls) }
        };

        let classes: Id<NSArray<NSObject, Owned>> = NSArray::from_vec(vec![nsurl_class]);
        let nsurl_array: Id<NSArray<NSObject>> = unsafe {
            let obj: *mut NSArray<NSObject> =
                msg_send![self.pasteboard, readObjectsForClasses:&*classes options:&*options];
            if obj.is_null() {
                return Ok(Vec::new());
            }
            Id::from_ptr(obj)
        };

        let results: Vec<String> = nsurl_array
            .to_vec()
            .into_iter()
            .filter_map(|obj| {
                let s: &NSString = unsafe {
                    let is_file: bool = msg_send![obj, isFileURL];
                    if !is_file {
                        return None;
                    }
                    let ret = msg_send![obj, path];
                    ret
                };
                Some(s.as_str().to_owned())
            })
            .collect();
        if results.is_empty() {
            return Ok(Vec::new());
        } else {
            Ok(results.into_iter().map(PathBuf::from).collect())
        }
    }
}

// this is a convenience function that both cocoa-rs and
// glutin define, which seems to depend on the fact that
// Option::None has the same representation as a null pointer
#[inline]
fn class(name: &str) -> *mut Class {
    unsafe { transmute(Class::get(name)) }
}
