/// SHA-256 by the processor's own instructions on a Mac and an iPhone, for lib/files/files_store.dart's `shaOfFile`:
/// CommonCrypto's, reached through `dart:ffi` (apple_sha_io.dart). A browser has no `dart:ffi`, and a build for one
/// can't so much as name it, so there [AppleSha.open] finds nothing (apple_sha_web.dart), as it finds nothing on
/// Android and Windows, and the file is read by the plain Dart reader.
library;

export 'apple_sha_io.dart' if (dart.library.js_interop) 'apple_sha_web.dart';
