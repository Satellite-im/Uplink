/// The password stretched by the browser's own JavaScript, for the app in a web page (Matt: "the full web client").
/// Argon2id at an account's settings (64 MiB, 3 passes) took 37 seconds in Dart compiled to JavaScript, on the page's
/// one thread, with the page frozen for all of it. web/argon2id.js is @noble/hashes' Argon2id, the one the browser
/// extension uses for the same accounts: about a second, on a worker's thread, the page drawing all the while
/// (argon2_browser_web.dart). Anywhere else there is no such thing, and the answer is null
/// (argon2_browser_none.dart): the password is stretched in Dart on an isolate, as ever.
///
/// Both give the same bytes: test/vectors/argon2id.json holds each to the same vectors (test/argon2_test.dart for
/// Dart's; tool/web/build-argon2.mjs and tool/web/e2e.mjs for the browser's).
library;

export 'argon2_browser_none.dart' if (dart.library.js_interop) 'argon2_browser_web.dart';
