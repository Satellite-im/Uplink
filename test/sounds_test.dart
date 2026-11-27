import 'dart:io';

import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/sounds.dart';

/// The interface sounds (lib/sounds.dart; Matt, 2026-11-16): the picked takes, the choices for a new message and
/// ringing, and everything else at a third of its loudness unless changed.
Uint8List _wav(List<int> samples) {
  final data = ByteData(44 + samples.length * 2);
  void text(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  data.setUint32(4, 36 + samples.length * 2, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 44100, Endian.little);
  data.setUint32(28, 88200, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(44 + i * 2, samples[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final played = <MethodCall>[];
  setUp(() {
    played.clear();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('ghost/sound'), (call) async {
      played.add(call);
      return null;
    });
  });

  test('a sound is scaled to its loudness in its samples, and nothing else in the file changes', () {
    final wav = _wav([10000, -10000, 32767, -32768]);
    final third = Sounds.scaled(wav, 0.33);
    final d = ByteData.sublistView(third);
    expect([for (var i = 0; i < 4; i++) d.getInt16(44 + i * 2, Endian.little)], [3300, -3300, 10813, -10813]);
    expect(third.sublist(0, 44), wav.sublist(0, 44));
    expect(Sounds.scaled(wav, 1), same(wav));
  });

  test('every sound and every choice is in the app', () async {
    for (final s in UiSound.values) {
      if (s.loud) continue;
      expect((await rootBundle.load('assets/sounds/${s.file}.wav')).lengthInBytes, greaterThan(1000), reason: s.file);
    }
    for (final c in [...Sounds.messageChoices.map((c) => 'message-in-${c.id}'), ...Sounds.ringChoices.map((c) => 'ring-in-${c.id}')]) {
      expect((await rootBundle.load('assets/sounds/$c.wav')).lengthInBytes, greaterThan(1000), reason: c);
    }
  });

  test('a new message and ringing at full loudness, the rest at a third; the choices played; off is silent', () async {
    final app = AppState();
    final s = Sounds.instance..start(app);
    expect((s.message, s.ring, s.quiet, s.on), ('4', '2', 33, true));
    s.play(UiSound.mute);
    s.play(UiSound.messageIn);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect([for (final c in played) (c.arguments as Map)['name']], ['mute', 'message-in-4']);
    final mute = await rootBundle.load('assets/sounds/mute.wav');
    expect((played.first.arguments as Map)['bytes'], isNot(mute.buffer.asUint8List()), reason: 'scaled down');
    final message = await rootBundle.load('assets/sounds/message-in-4.wav');
    expect((played.last.arguments as Map)['bytes'], message.buffer.asUint8List(), reason: 'as it is');

    played.clear();
    s.setRing('3');
    s.loop(UiSound.ringIn);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect([for (final c in played) (c.arguments as Map)['name']], ['ring-in-3', 'ring-in-3']);
    expect((played.last.arguments as Map)['loop'], isTrue);
    s.stopLoop(UiSound.ringIn);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(played.last.method, 'stop');

    played.clear();
    s.setOn(false);
    s.play(UiSound.reaction);
    s.loop(UiSound.ringIn);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(played, isEmpty);
    s.setOn(true);
  });

  // Matt, 2026-11-16: "use muted-bell-low".
  test('the muted bell is the message sound: chosen once for everyone, and a later choice of theirs stays', () async {
    final app = AppState()..set('sound_message', '2');
    final s = Sounds.instance..start(app);
    expect(s.message, '4', reason: 'a sound chosen before is moved to the muted bell, once');
    expect(Sounds.messageChoices.first.label, 'Muted bell');
    s.setMessage('3');
    Sounds.instance.start(app);
    expect(s.message, '3', reason: 'started again, the choice made since stays');
    expect(File('android/app/src/main/res/raw/notify_message_4.ogg').lengthSync(), greaterThan(1000), reason: 'its notification sound on Android');
  });
}
