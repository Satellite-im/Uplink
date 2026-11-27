import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/sounds.dart';
import 'package:ghost_messaging/voice/rtc.dart';
import 'package:ghost_messaging/voice/voice_settings.dart';
import 'package:integration_test/integration_test.dart';

import 'core_audio_fixture.dart';

/// The microphone and the speaker chosen, on a real Mac (Matt, 2026-11-23: "switching input and output devices
/// doesn't work ... it seems to only use the default device"). Until WebRTC's sound had started (a first connection
/// made), the Mac's WebRTC listed only "default" for each and answered "deviceId not found!" to any other, so the
/// device chosen in Settings was dropped at the start of every call. Run on a Mac whose microphone may be used:
/// `flutter test integration_test/audio_devices_test.dart -d macos`. Against the code before the fix the first check
/// fails: only "default" is listed.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a chosen microphone and speaker are listed, used from the start of a call, and switched in it', (tester) async {
    // Before anything else in this app has started WebRTC's sound: what Settings lists.
    final inputs = await RtcMedia.devices('audioinput'), outputs = await RtcMedia.devices('audiooutput');
    debugPrint('audio devices: in ${[for (final d in inputs) '${d.deviceId} (${d.label})']}, out ${[for (final d in outputs) '${d.deviceId} (${d.label})']}');
    final mic = inputs.where((d) => d.deviceId != 'default').firstOrNull, speaker = outputs.where((d) => d.deviceId != 'default').firstOrNull;
    expect(mic, isNotNull, reason: 'only the system\'s own microphone was listed: no other could be chosen');
    expect(speaker, isNotNull, reason: 'only the system\'s own speaker was listed');
    // Chosen by id, as a call does at its start: found.
    await RtcMedia.sound.selectInput(mic!.deviceId);
    await RtcMedia.sound.selectOutput(speaker!.deviceId);
    final busyBefore = CoreAudioFixture.running(mic.deviceId);

    // A call of two on this Mac, each side played at nothing so the room does not hear itself.
    final a = RtcMedia(settings: VoiceSettings(input: mic.deviceId, inputName: mic.label, output: speaker.deviceId, outputName: speaker.label)), b = RtcMedia();
    await a.start();
    await b.start();
    expect(a.inputMissing, isFalse);
    expect(a.outputMissing, isFalse);
    late final dynamic toB, toA;
    toA = a.peer('b', onCandidate: (c) => unawaited(toB.addCandidate(c)));
    toB = b.peer('a', onCandidate: (c) => unawaited(toA.addCandidate(c)));
    final offer = await toA.makeOffer();
    final answer = await toB.takeOffer(offer);
    await toA.takeAnswer(answer);
    a.setPeerVolume('b', 0);
    b.setPeerVolume('a', 0);

    // B hears A: what A's microphone takes reaches B.
    Future<void> heard(String when) async {
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if ((b.levels.value['a'] ?? 0) > 0) return;
      }
      fail('B heard nothing from A $when');
    }

    await heard('at the start');
    if (!busyBefore) expect(CoreAudioFixture.running(mic.deviceId), isTrue, reason: 'the chosen microphone is the one running');
    expect(CoreAudioFixture.running(speaker.deviceId), isTrue, reason: 'the chosen speaker is the one playing');

    // Switched in the call, without leaving it: to the system's own and back.
    await a.setInput('');
    b.levels.value = const {};
    await heard('after switching to the system\'s own microphone');
    await a.setInput(mic.deviceId, name: mic.label);
    b.levels.value = const {};
    await heard('after switching back to the chosen microphone');
    await a.setOutput('');
    await a.setOutput(speaker.deviceId, name: speaker.label);
    expect(CoreAudioFixture.running(speaker.deviceId), isTrue);
    // A device not connected: the system's own, said so.
    await a.setInput('no-such-microphone', name: 'Nothing');
    expect(a.inputMissing, isTrue);
    b.levels.value = const {};
    await heard('with a microphone that is not connected');
    await a.stop();
    await b.stop();

    // The app's sounds (the ring) through the chosen speaker, and through the system's own where it is not connected.
    const sound = MethodChannel('ghost/sound');
    // Played very quietly: this is someone's Mac.
    final wav = Sounds.scaled((await rootBundle.load('assets/sounds/ring-in-1.wav')).buffer.asUint8List(), 0.03);
    for (final out in [speaker.deviceId, 'no-such-speaker']) {
      await sound.invokeMethod<void>('play', {'name': 'ring', 'bytes': wav, 'loop': true, 'output': out});
      var playing = false;
      for (var i = 0; i < 30 && !playing; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        playing = CoreAudioFixture.running(speaker.deviceId);
      }
      await sound.invokeMethod<void>('stop');
      expect(playing, isTrue, reason: 'the ring played through $out');
    }
  });
}
