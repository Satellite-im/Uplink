import '../platform_info.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether Windows lowers every other sound on the computer while the app is in a call (Matt, 2026-11-21: "When on
/// windows in a call it's making my background audio on my PC quieter is this a setting we can turn off?"). Windows
/// does that to any app talking through a microphone unless the app says it does not want it; the app says so unless
/// "Lower other sounds in calls" is switched on in Settings › Voice and video (VoiceSettings.duckOthers).
///
/// A Mac does the same: Apple's voice processing, which a call's microphone goes through, turns every other app down
/// while it is on, and more as people speak (Matt, 2026-11-25: "when i'm playing the audio on spotify while in a call it
/// makes spotify quieter"). It is asked for the least it does, which is not quite nothing, and for no turning down and up
/// with the voices; macOS 14 and later.
///
/// The native halves are windows/runner/ducking.cpp and macos/Runner/VoiceFx.swift, on "ghost/ducking". Elsewhere nothing
/// is asked.
class Ducking {
  Ducking._();
  static const _channel = MethodChannel('ghost/ducking');

  /// This device lowers other sounds in a call, and can be told not to.
  static bool get here => !kIsWeb && (PlatformInfo.isWindows || PlatformInfo.isMacOS);

  /// Said before a call opens the microphone and again once it is open (VoiceFx.apply), and when the switch changes.
  static Future<void> apply({required bool duckOthers}) async {
    if (!here) return;
    try {
      await _channel.invokeMethod<int>('set', {'leaveOthers': !duckOthers});
    } on MissingPluginException {
      // An older Windows build: Windows does as it does.
    } on PlatformException {
      // Likewise.
    }
  }
}
