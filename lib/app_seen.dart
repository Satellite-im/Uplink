import 'package:flutter/widgets.dart';

/// Whether anyone can see the app now: on the screen (in front, or beside another window), not put away, minimised or
/// behind a locked screen.
///
/// What is only ever looked at stops while it can't be: a call's sound goes on, but how loud each voice is, read
/// several times a second to ripple a face, is not read (lib/voice/rtc.dart). Matt, 2026-11-24, with Android's battery
/// page saying "High CPU usage" under the app: "please see what you can do about the high CPU usage"; a call cost the
/// same with the phone in a pocket as with its screen on (docs/performance-audit.md, "Calls").
///
/// True until [follow] has been called and the app has been put away: where nothing follows the app's state (a
/// test with no binding), everything runs as if seen.
class AppSeen {
  AppSeen._();

  /// Whether the app can be seen now. Told when that changes.
  static final ValueNotifier<bool> now = ValueNotifier(true);

  static AppLifecycleListener? _listener;

  /// Whether the app can be seen in [state]: in front, or still on the screen without the keyboard's attention (a
  /// computer's window behind another, a phone's with the shade pulled down). Not while hidden, paused or detached.
  static bool seenIn(AppLifecycleState? state) => state == null || state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;

  /// Begins following the app's state, once. Safe to call again, and where there is no app to follow.
  static void follow() {
    if (_listener != null) return;
    try {
      now.value = seenIn(WidgetsBinding.instance.lifecycleState);
      _listener = AppLifecycleListener(onStateChange: (state) => now.value = seenIn(state));
    } catch (_) {
      // No binding (a plain test): nothing to follow, and everything stays as if seen.
    }
  }

  /// For a test: as if the app were put away or brought back.
  @visibleForTesting
  static void set(bool seen) => now.value = seen;
}
