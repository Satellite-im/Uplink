import 'dart:io' show Platform;

/// Where there is `dart:io` (lib/platform_info.dart): `Platform`'s own answers, each handed on as it is. The one file
/// in lib/ that asks `Platform`.
abstract final class PlatformInfo {
  /// Running in a browser: never, here.
  static const bool isWeb = false;

  // `vm:platform-const`, as `Platform`'s own are marked: a release build is made for one platform, and with this the
  // compiler knows these answers as it builds, so what is written for another platform (`if (PlatformInfo.isWindows)
  // …`) is left out of the app as it was when the screens asked `Platform` themselves. Without it each is a call made
  // while the app runs, and every platform's code is carried by every build.
  @pragma('vm:platform-const')
  static bool get isAndroid => Platform.isAndroid;
  @pragma('vm:platform-const')
  static bool get isIOS => Platform.isIOS;
  @pragma('vm:platform-const')
  static bool get isMacOS => Platform.isMacOS;
  @pragma('vm:platform-const')
  static bool get isWindows => Platform.isWindows;
  @pragma('vm:platform-const')
  static bool get isLinux => Platform.isLinux;

  @pragma('vm:platform-const')
  static String get operatingSystem => Platform.operatingSystem;
  static String get operatingSystemVersion => Platform.operatingSystemVersion;
  static String get localHostname => Platform.localHostname;
  static int get numberOfProcessors => Platform.numberOfProcessors;
  @pragma('vm:platform-const')
  static String get pathSeparator => Platform.pathSeparator;
  static Map<String, String> get environment => Platform.environment;
  static String get resolvedExecutable => Platform.resolvedExecutable;
}
