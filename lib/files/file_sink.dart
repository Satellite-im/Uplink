/// Where a file that comes down goes in a browser (FilesStore, docs/OPEN_NETWORK.md part 6), in place of the app's
/// part file and cache folder: each chunk handed to the browser as it is opened, never the whole file in the app's own
/// memory, then held for the tab's life under an address the page can show or save (file_sink_web.dart: a `Blob`,
/// which Chromium and Firefox put on disk once it is big; Safari holds it in memory). Away from a browser (a test of
/// the browser's way on a computer) the bytes are held in memory (file_sink_none.dart).
library;

import 'dart:typed_data';

export 'file_sink_none.dart' if (dart.library.js_interop) 'file_sink_web.dart';

/// One file coming down: [add] its plain bytes in order, then [finish] for the address it is held under, or [abort].
abstract class HeldSink {
  void add(Uint8List plain);

  /// The address it is held under (a `blob:` one in a browser). Said to be a sound or a video where [mime] says it
  /// is one, for the page's own player; anything else is `application/octet-stream` ([heldType]), so nothing it holds
  /// is ever taken for a page (an HTML file, or an SVG picture, with a script in it).
  String finish(String mime);
  void abort();
}

/// The kind a held file is said to be: a sound or a video as itself, everything else plain bytes.
String heldType(String mime) => RegExp(r'^(audio|video)/[a-z0-9.+-]+$').hasMatch(mime.toLowerCase()) ? mime.toLowerCase() : 'application/octet-stream';
