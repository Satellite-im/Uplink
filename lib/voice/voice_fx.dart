import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ducking.dart';
import 'voice_settings.dart';

/// The microphone's own processing, done natively inside WebRTC's capture path (Matt, 2026-11-15: "build in like krisp
/// noise supression or other fancy noise suppression tools, add a volume slider for input ... with overboosting";
/// RNNoise + DeepFilterNet chosen): the sound sent is boosted or lowered and, where chosen, cleaned by RNNoise or
/// DeepFilterNet before Opus.
///
/// The native halves (channel `ghost/voicefx`) sit in flutter_webrtc's capture post-processing hook: android
/// VoiceFx.kt, macos VoiceFx.swift, and on Windows the patched flutter_webrtc (third_party/flutter_webrtc). Each runs
/// native/voicefx, the same C for all three.
class VoiceFx {
  VoiceFx._();
  static const _channel = MethodChannel('ghost/voicefx');

  /// What this device can run, once asked; empty where there is no native half (tests, an old build).
  static Set<NoiseMode> available = const {};
  static bool _asked = false;

  /// Asks the native half what it runs.
  static Future<Set<NoiseMode>> modes() async {
    if (_asked) return available;
    try {
      final said = await _channel.invokeListMethod<String>('modes') ?? const [];
      available = {for (final s in said) ?NoiseMode.named(s)};
      liveSupported = said.contains('live');
      effectsSupported = said.contains('effects');
      levelSupported = said.contains('level');
      levelsSupported = said.contains('levels');
      closesAside = said.contains('aside');
    } on MissingPluginException {
      available = const {};
    } on PlatformException {
      available = const {};
    }
    _asked = true;
    return available;
  }

  /// For a test: what the device can run set to [to], as if asked; with none, asked afresh next time.
  @visibleForTesting
  static void reset([Set<NoiseMode> to = const {}, bool live = false, bool effects = false, bool level = false, bool levels = false]) {
    available = to;
    liveSupported = live;
    effectsSupported = effects;
    levelSupported = level;
    levelsSupported = levels;
    closesAside = false;
    _asked = to.isNotEmpty || live;
  }

  // --- live voice changing (lib/voice/live_changer.dart) -------------------------------------------------------------

  /// The native half can change a call's voice live: keep what is said and play back what it is fed.
  static bool liveSupported = false;

  /// The native half makes voice effects as it goes (native/voicefx voicefx_effect).
  static bool effectsSupported = false;

  /// The native half can say how loud the microphone is ([level]): the Mac's.
  static bool levelSupported = false;

  /// How loud the microphone has been since last asked, 0 to 1 (the loudest sample, after the processing): for the
  /// microphone test (GMFB-20).
  static Future<double> level() async {
    try {
      return (await _channel.invokeMethod<double>('level') ?? 0).clamp(0.0, 1.0);
    } catch (_) {
      return 0;
    }
  }

  // --- how loud each voice in a call is (lib/voice/rtc.dart, RtcMedia._readLevelsOnce) -----------------------------

  /// The native half can say how loud the microphone and each tapped voice are ([levels]): the phone's (android
  /// VoiceFx.kt). Where it can't, a call reads each from its connection's statistics, as it always did.
  static bool levelsSupported = false;

  /// Taps [trackId], someone's decoded voice, under [key], so that [levels] says how loud it is. False where the
  /// native half holds no such voice now: that person's level is then read from their connection's statistics.
  static Future<bool> hear(String key, String trackId) async {
    try {
      return await _channel.invokeMethod<bool>('hear', {'key': key, 'track': trackId}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Takes the tap off [key]'s voice.
  static Future<void> unhear(String key) async {
    try {
      await _channel.invokeMethod<void>('unhear', {'key': key});
    } catch (_) {}
  }

  /// How loud the microphone (`me`) and each tapped voice (by its key) have been since last asked, 0 to 1. `me` is
  /// left out where the native half was handed none of the microphone since then. Null where it could not be asked.
  static Future<Map<String, double>?> levels() async {
    try {
      final said = await _channel.invokeMapMethod<String, Object?>('levels');
      if (said == null) return null;
      return {for (final e in said.entries) if (e.value is num) e.key: (e.value as num).toDouble().clamp(0.0, 1.0)};
    } catch (_) {
      return null;
    }
  }

  // --- closing a connection off the main thread (lib/voice/rtc.dart, RtcMedia.closeConnection) ----------------------

  /// The native half can close a WebRTC connection off the main thread ([closeAside]): the Mac's
  /// (macos/Runner/VoiceFx.swift).
  static bool closesAside = false;

  /// Closes the connection the platform knows as [id], off the main thread, and comes back once it is closed. False
  /// where the native half holds no such connection (already closed) or can't.
  static Future<bool> closeAside(String id) async {
    try {
      return await _channel.invokeMethod<bool>('closeConnection', {'id': id}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// A voice effect on what goes into the call, made on this device as it is said: one of [VoiceEffect]'s names,
  /// or 'none'.
  static Future<bool> effect(String name) async {
    try {
      return await _channel.invokeMethod<bool>('effect', {'name': name}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// While [on], what the microphone says is kept for [take] and only what is [feed]-ed goes into the call.
  static Future<bool> live(bool on) async {
    try {
      return await _channel.invokeMethod<bool>('live', {'on': on}) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// What was said since last asked: 16-bit little-endian mono at 16 kHz.
  static Future<Uint8List> take({int most = 32000}) async {
    try {
      return await _channel.invokeMethod<Uint8List>('take', {'most': most}) ?? Uint8List(0);
    } on MissingPluginException {
      return Uint8List(0);
    } on PlatformException {
      return Uint8List(0);
    }
  }

  /// The changed voice to play into the call, 16-bit little-endian mono at [rate]; how much is then queued, in ms.
  static Future<int> feed(Uint8List pcm, int rate) async {
    try {
      return await _channel.invokeMethod<int>('feed', {'pcm': pcm, 'rate': rate}) ?? 0;
    } on MissingPluginException {
      return 0;
    } on PlatformException {
      return 0;
    }
  }

  /// Sets what is done to the microphone: [mode] (only RNNoise and DeepFilterNet are native; others are none here)
  /// and [gain], 1 for as it is, up to 2 for boosted.
  static Future<void> configure({required NoiseMode mode, required double gain}) async {
    final native = mode == NoiseMode.rnnoise || mode == NoiseMode.deepfilter ? mode.name : 'off';
    try {
      await _channel.invokeMethod<void>('configure', {'mode': native, 'gain': gain});
    } on MissingPluginException {
      // No native half: the sound goes as it is.
    } on PlatformException {
      // Refused: likewise.
    }
  }

  /// Applies [s] as it stands.
  static Future<void> apply(VoiceSettings s) async {
    final modes = await VoiceFx.modes();
    await configure(mode: s.noiseOn(modes), gain: s.inputVolume / 100);
    // Whether Windows lowers other sounds in the call, said with the rest before the microphone opens and after.
    await Ducking.apply(duckOthers: s.duckOthers);
  }
}
