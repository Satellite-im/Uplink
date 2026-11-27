/// In a browser (lib/platform_info.dart), where `dart:io`'s `Platform` throws whatever it is asked: the same
/// questions, answered without it. Plain Dart, so a test on a computer reads these answers too.
abstract final class PlatformInfo {
  /// Running in a browser: always, here.
  static const bool isWeb = true;

  // A browser is none of the five, whatever it runs on: what the app does for each (channels to Kotlin and Swift,
  // helpers started as processes, folders on a disk) isn't there to be asked for.
  static bool get isAndroid => false;
  static bool get isIOS => false;
  static bool get isMacOS => false;
  static bool get isWindows => false;
  static bool get isLinux => false;

  static String get operatingSystem => 'web';

  /// Not known without asking the browser itself.
  static String get operatingSystemVersion => '';
  static String get localHostname => 'browser';

  /// One: a browser has no isolates to share work between (lib/aside.dart), so there is nothing to split it for.
  static int get numberOfProcessors => 1;
  static String get pathSeparator => '/';
  static Map<String, String> get environment => const <String, String>{};

  /// No program on a disk.
  static String get resolvedExecutable => '';
}
