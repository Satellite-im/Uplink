/// What a Files space asks of a page in a browser (docs/OPEN_NETWORK.md, part 6), where the app asks its device
/// (lib/files/file_platform.dart): choosing files with the browser's own picker, files dropped on the page, and saving
/// a file that came down to the browser's downloads. Each picked or dropped file is a [FileSource] read a piece at a
/// time from the browser's `File`, never as a path and never whole (browser_files_web.dart). Anywhere else there is
/// none of it (browser_files_none.dart).
library;

export 'browser_files_none.dart' if (dart.library.js_interop) 'browser_files_web.dart';
