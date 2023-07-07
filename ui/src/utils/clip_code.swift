import Cocoa

// Code to get all files path saved in clipboard
let pasteboard = NSPasteboard.general
var paths = ""
if let types = pasteboard.types {
    if types.contains(.fileURL) {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                paths += url.path + "\n"
            }
        }
    }
}
// print all paths to get this result as string in rust code
print(paths)
