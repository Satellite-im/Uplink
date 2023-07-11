import Cocoa

// Code to get all files path saved in clipboard
let pasteboard = NSPasteboard.general

// Check if the pasteboard contains file URLs, and exit early if it doesn't
guard let types = pasteboard.types, types.contains(.fileURL) else {
    print("")
    exit(0)
}

// At this point,the pasteboard contains file URLs
var pathArray = [String]()
if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
    for url in urls {
        pathArray.append(url.path)
    }
}

let paths = pathArray.joined(separator: "\n")

// Print all paths to get this result as string in rust code
print(paths)