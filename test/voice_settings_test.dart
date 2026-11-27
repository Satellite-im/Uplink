import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/voice/voice.dart';
import 'package:ghost_messaging/voice/voice_fx.dart';
import 'package:ghost_messaging/voice/voice_settings.dart';

/// Settings › Voice and video's choices and what they make of a call (Matt, 2026-11-15: "can we support 4k? and flac
/// audio? also build in like krisp noise supression or other fancy noise suppression tools, add a volume slider for
/// input and output volume with overboosting"), and the native half they are handed to (lib/voice/voice_fx.dart).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // AppState keeps each choice on the phone too: no phone here.
  setUpAll(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null));

  test('what an untouched phone uses: RNNoise, 100% both ways, 1080p, 510 kb/s stereo', () {
    final v = VoiceSettings.of(AppState());
    expect(v.noise, NoiseMode.rnnoise);
    expect((v.inputVolume, v.outputVolume), (100, 100));
    expect(v.video, 1080);
    expect((v.sendKbps, v.sendStereo, v.useEcho), (510, true, true));
  });

  test('the old noise switch reads as WebRTC\'s own; a choice made since wins', () {
    final app = AppState()..setFlag('voice_noise', true);
    expect(VoiceSettings.of(app).noise, NoiseMode.webrtc);
    app.set('voice_noise_mode', 'deepfilter');
    expect(VoiceSettings.of(app).noise, NoiseMode.deepfilter);
  });

  test('Windows is told to leave other sounds alone in calls unless the person switches the lowering on', () {
    final app = AppState();
    expect(VoiceSettings.of(app).duckOthers, isFalse);
    app.setFlag('voice_duck_others', true);
    final v = VoiceSettings.of(app);
    expect(v.duckOthers, isTrue);
    // Kept through a change of devices in the call.
    expect(v.copyWith(input: 'usb').duckOthers, isTrue);
  });

  test('volumes are held to 0–200%', () {
    final app = AppState()
      ..set('voice_in_volume', '350')
      ..set('voice_out_volume', '-4');
    final v = VoiceSettings.of(app);
    expect((v.inputVolume, v.outputVolume), (200, 0));
  });

  test('Music mode: 510 kb/s stereo with nothing done to the microphone', () {
    final app = AppState()
      ..set('voice_kbps', '64')
      ..setFlag('voice_stereo', false)
      ..setFlag('voice_gain', true)
      ..setFlag('voice_music', true);
    final v = VoiceSettings.of(app);
    expect((v.sendKbps, v.sendStereo, v.useEcho, v.useGain), (510, true, false, false));
    expect(v.noiseOn({NoiseMode.rnnoise, NoiseMode.deepfilter}), NoiseMode.off);
  });

  test('a noise suppression this device cannot run falls back to WebRTC\'s own', () {
    const v = VoiceSettings(noise: NoiseMode.deepfilter);
    expect(v.noiseOn({NoiseMode.rnnoise, NoiseMode.deepfilter}), NoiseMode.deepfilter);
    expect(v.noiseOn({NoiseMode.rnnoise}), NoiseMode.rnnoise, reason: 'a phone runs RNNoise alone: the next best');
    expect(const VoiceSettings().noiseOn(const {}), NoiseMode.webrtc, reason: 'no native half at all');
    expect(const VoiceSettings(noise: NoiseMode.off).noiseOn({NoiseMode.rnnoise}), NoiseMode.off);
  });

  test('4K: the whole picture at 25 Mb/s to one other; to more, each copy the size 1080p would send', () {
    const k4 = VoiceSettings(video: 2160), hd = VoiceSettings();
    expect(k4.videoSize, (width: 3840, height: 2160));
    expect(k4.sendTo(1, videoFor(1)), (scale: 1.0, bitrate: 25000000));
    expect(hd.sendTo(1, videoFor(1)), (scale: 1.0, bitrate: 12000000));
    for (final n in [2, 3, 5]) {
      final four = k4.sendTo(n, videoFor(n)), full = hd.sendTo(n, videoFor(n));
      expect(four.bitrate, full.bitrate, reason: 'the same bit rate to $n');
      expect(2160 / four.scale, closeTo(1080 / full.scale, 0.01), reason: 'the same picture height to $n');
    }
    expect(const VoiceSettings(video: 480).sendTo(1, videoFor(1)).bitrate, 1500000, reason: 'a lower choice caps it');
  });

  group('VoiceFx', () {
    const channel = MethodChannel('ghost/voicefx');
    final said = <MethodCall>[];
    setUp(() {
      said.clear();
      VoiceFx.reset();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        said.add(call);
        return call.method == 'modes' ? ['rnnoise'] : true;
      });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      VoiceFx.reset();
    });

    test('asks what the device runs once, and hands it the mode and the gain', () async {
      await VoiceFx.apply(const VoiceSettings(inputVolume: 150));
      await VoiceFx.apply(const VoiceSettings(noise: NoiseMode.deepfilter, inputVolume: 80));
      expect(said.where((c) => c.method == 'modes'), hasLength(1));
      final configured = said.where((c) => c.method == 'configure').map((c) => c.arguments as Map).toList();
      expect(configured[0], {'mode': 'rnnoise', 'gain': 1.5});
      expect(configured[1], {'mode': 'rnnoise', 'gain': 0.8}, reason: 'DeepFilterNet cannot run here: RNNoise, the next best');
    });

    test('with no native half the call goes on, and WebRTC\'s own is used', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      await VoiceFx.apply(const VoiceSettings());
      expect(VoiceFx.available, isEmpty);
      expect(const VoiceSettings().noiseOn(VoiceFx.available), NoiseMode.webrtc);
    });
  });

  // Matt, 2026-11-15: "on desktop use DeepFilter as default and on mobile use the RNN as default".
  test('until one is chosen, a computer uses DeepFilterNet and a phone RNNoise; DeepFilterNet unable to run gives RNNoise', () {
    for (final (platform, want) in [
      (TargetPlatform.macOS, NoiseMode.deepfilter),
      (TargetPlatform.windows, NoiseMode.deepfilter),
      (TargetPlatform.linux, NoiseMode.deepfilter),
      (TargetPlatform.android, NoiseMode.rnnoise),
      (TargetPlatform.iOS, NoiseMode.rnnoise),
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      expect(VoiceSettings.of(AppState()).noise, want, reason: '$platform');
    }
    debugDefaultTargetPlatformOverride = null;
    expect(const VoiceSettings(noise: NoiseMode.deepfilter).noiseOn({NoiseMode.rnnoise}), NoiseMode.rnnoise);
    expect(const VoiceSettings(noise: NoiseMode.deepfilter).noiseOn({}), NoiseMode.webrtc);
  });
}
