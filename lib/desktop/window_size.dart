import '../platform_info.dart';

import 'package:flutter/services.dart';

/// Under `flutter test`, which draws no window.
bool get isUnderTest => PlatformInfo.environment.containsKey('FLUTTER_TEST');

/// The computer's window: small while signing up or in, its own size for the app (Matt, 2026-11-20: "make the sign up /
/// sign in window smaller"), as Discord's sign-in is a small window of its own. The Mac's and Windows' halves do it
/// (MainFlutterWindow.swift, splash.cpp), as they make the launch splash small.
abstract final class DeskWindow {
  static const _channel = MethodChannel('ghost_desktop/window');
  static bool? _compact;

  /// Small ([on]) or the window's own size; said once for each change.
  static Future<void> compact(bool on) async {
    if (_compact == on || isUnderTest) return;
    _compact = on;
    try {
      await _channel.invokeMethod<void>('compact', on);
    } catch (_) {
      // A window that can't (Linux): as it is.
    }
  }

  /// The splash given way to: straight to the small window for signing up, else the window's own size.
  static Future<void> leaveSplash({required bool compact}) async {
    if (isUnderTest) return;
    if (compact) return DeskWindow.compact(true);
    _compact = false;
    try {
      await _channel.invokeMethod<void>('splash', false);
    } catch (_) {}
  }
}
