/// What kind of device this is and what it says of itself, wherever the app runs (Matt: "the full web client"). On a
/// phone and a computer these are `dart:io`'s `Platform`'s own answers, each exactly as it gives them
/// (platform_info_io.dart). A browser has no `dart:io`: there every one of `Platform`'s getters throws, so the first
/// "is this Android?" stopped the app; platform_info_web.dart answers there instead, and is none of the five.
///
/// Everything in lib/ asks here and never `Platform` itself (test/platform_info_test.dart reads the files to see).
/// Not Flutter's `defaultTargetPlatform`, which is the look to draw rather than the device the code runs on: Android's
/// under `flutter test` on a Mac, the Mac's in a browser on one.
library;

export 'platform_info_io.dart' if (dart.library.js_interop) 'platform_info_web.dart';
