import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStreamTrack;

/// A phone's or a computer's: WebRTC plays what arrives itself, at the volume RtcMedia gives each track
/// (lib/voice/call_sound.dart).
class CallSound {
  /// Whether the app plays what arrives itself: only in a browser.
  static const bool playsItself = false;

  /// Whether a speaker can be chosen for a call: the native halves choose one for the whole device.
  static bool get canChooseOutput => true;

  /// The loudest a person can be made: twice as loud as they arrive.
  static const double most = 2.0;

  void play(String id, MediaStreamTrack track) {}
  void set(String id, {required double volume, required bool silent}) {}
  Future<bool> output(String deviceId) async => false;
  void stop(String id) {}
  void stopAll() {}
}
