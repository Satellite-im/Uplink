/// A Files space's chunks sealed and opened without holding the screen still (lib/net/file_seal.dart): FileSeal's own
/// chunks, nonces and bindings ([FileSeal.runChunks], [FileSeal.nonceOf], [FileSeal.aadOf]), with the AES-GCM done
/// where it is quickest without the page or the app waiting on it.
///
/// - On a phone or a computer, FileSeal itself on another isolate (file_seal_async_io.dart): what the app always did.
/// - In a browser, the browser's own AES-GCM and SHA-256 (WebCrypto, file_seal_async_web.dart), which give the same
///   bytes (the sealed bytes then the 16-byte tag) and run beside the page. FastGcm's browser half is pointycastle's
///   GCM, a megabyte or two a second, done in place: a 4 MB piece would hold the page still for seconds.
///
/// tool/web/e2e.mjs --files holds a browser's to the app's: what one browser seals another opens, and the bytes that
/// come down are the bytes that went up; test/files_web_test.dart holds this file's walk to FileSeal's.
library;

export 'file_seal_async_io.dart' if (dart.library.js_interop) 'file_seal_async_web.dart';
