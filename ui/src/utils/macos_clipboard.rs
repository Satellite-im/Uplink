// use objc::msg_send;
// use objc::runtime::{Class, Object};
// use objc_foundation::{INSArray, INSString};
// use objc_foundation::{NSArray, NSDictionary, NSObject, NSString};
// use objc_id::{Id, Owned};
// use std::mem::transmute;
// use std::path::PathBuf;

// pub(crate) fn read_clipboard() -> Result<Vec<String>, Error> {
//     let clipboard = Clipboard::new()?;
//     clipboard.read()
// }

// pub struct Clipboard {
//     pasteboard: Id<Object>,
// }

// // required to bring NSPasteboard into the path of the class-resolver
// #[link(name = "AppKit", kind = "framework")]
// extern "C" {
//     // NSString
//     static NSPasteboardURLReadingFileURLsOnlyKey: &'static Object;
// }

// impl Clipboard {
//     pub fn new() -> Result<Clipboard, Error> {
//         let ns_pasteboard = class(NSPasteboard);
//         let pasteboard: *mut Object = unsafe { msg_send![ns_pasteboard, generalPasteboard] };
//         if pasteboard.is_null() {
//             return Err(Error::SystemError(
//                 "NSPasteboard#generalPasteboard returned null".into(),
//             ));
//         }
//         let pasteboard: Id<Object> = unsafe { Id::from_ptr(pasteboard) };
//         Ok(Clipboard { pasteboard })
//     }

//     pub fn read(&self) -> Result<Vec<String>, Error> {
//         let ns_dict = class(NSDictionary);
//         let ns_number = class(NSNumber);
//         let options: Id<NSDictionary<NSObject, NSObject>> = unsafe {
//             let obj: Id<NSObject> =
//                 Id::from_ptr(msg_send![ns_number, numberWithBool: objc::runtime::YES]);
//             Id::from_ptr(
//                 msg_send![ns_dict, dictionaryWithObject: &*obj forKey: NSPasteboardURLReadingFileURLsOnlyKey],
//             )
//         };

//         let nsurl_class: Id<NSObject> = {
//             let cls: Id<Class> = unsafe { Id::from_ptr(class("NSURL")) };
//             unsafe { transmute(cls) }
//         };

//         let classes: Id<NSArray<NSObject, Owned>> = NSArray::from_vec(vec![nsurl_class]);
//         let nsurl_array: Id<NSArray<NSObject>> = unsafe {
//             let obj: *mut NSArray<NSObject> =
//                 msg_send![self.pasteboard, readObjectsForClasses:&*classes options:&*options];
//             if obj.is_null() {
//                 return Err(Error::NoFiles);
//             }
//             Id::from_ptr(obj)
//         };

//         let results: Vec<_> = nsurl_array
//             .to_vec()
//             .into_iter()
//             .filter_map(|obj| {
//                 let s: &NSString = unsafe {
//                     let is_file: bool = msg_send![obj, isFileURL];
//                     if !is_file {
//                         return None;
//                     }
//                     let ret = msg_send![obj, path];
//                     ret
//                 };
//                 Some(s.as_str().to_owned())
//             })
//             .collect();
//         if results.is_empty() {
//             Err(Error::NoFiles)
//         } else {
//             Ok(results)
//         }
//     }
// }

// // this is a convenience function that both cocoa-rs and
// // glutin define, which seems to depend on the fact that
// // Option::None has the same representation as a null pointer
// #[inline]
// fn class(name: &str) -> *mut Class {
//     unsafe { transmute(Class::get(name)) }
// }

// /// Read the system-wide clipboard. Returns a list of one or more absolute file paths or an error.
// pub fn read() -> Result<Vec<PathBuf>, Error> {
//     read_clipboard().map(|strs| strs.into_iter().map(PathBuf::from).collect())
// }

// #[derive(Debug, PartialEq)]
// pub enum Error {
//     NoFiles,
//     SystemError(String),
// }
