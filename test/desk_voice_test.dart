import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/desktop/desk_voice.dart';
import 'package:ghost_messaging/files/files_model.dart';
import 'package:ghost_messaging/net/crypto.dart' show NetCrypto;
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/standalone/standalone.dart';
import 'package:ghost_messaging/ui/voice.dart';
import 'package:ghost_messaging/voice/hangout.dart';

import 'support/list_harness.dart';

/// Voice messages from a computer (GMFB-32, from the Uplink gap review: "voice messages from the desktop"): the
/// computer's own recorder asked through lib/desktop/desk_voice.dart, for a text (the carrier's limit) or a file (a
/// network's chat, a space, a friend), the recording kept as the `.m4a` a phone records, and the recorder's row.
class _Recorder {
  final calls = <MethodCall>[];
  Map<String, Object?> startAnswer = {'ok': true};
  Map<String, Object?> levelAnswer = {'level': 0.4, 'full': false};
  Uint8List? stopAnswer;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    return switch (call.method) {
      'voiceStart' => startAnswer,
      'voiceLevel' => levelAnswer,
      'voiceStop' => stopAnswer,
      _ => null,
    };
  }

  List<String> get methods => [for (final c in calls) c.method];
}

class _Calls implements SmsCalls {
  final asked = <(String, Object?)>[];
  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    asked.add((method, arguments));
    return (method == 'voiceStart' ? {'ok': true, 'seconds': 300} : 0.0) as T?;
  }
}

/// A real `.m4a` of [seconds] of a tone, made by the Mac's own AAC encoder (afconvert), as DeskSound.swift records;
/// null off a Mac.
Uint8List? macM4a(Directory dir, double seconds) {
  if (!Platform.isMacOS) return null;
  final rate = 16000, n = (rate * seconds).round();
  final pcm = BytesBuilder();
  // A WAV header and a 440 Hz tone.
  final data = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    data.setInt16(i * 2, (8000 * (i % 36 < 18 ? 1 : -1)), Endian.little);
  }
  final header = ByteData(44);
  void s(int at, String t) => t.codeUnits.asMap().forEach((i, c) => header.setUint8(at + i, c));
  s(0, 'RIFF');
  header.setUint32(4, 36 + n * 2, Endian.little);
  s(8, 'WAVEfmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, rate, Endian.little);
  header.setUint32(28, rate * 2, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  s(36, 'data');
  header.setUint32(40, n * 2, Endian.little);
  pcm
    ..add(header.buffer.asUint8List())
    ..add(data.buffer.asUint8List());
  final wav = File('${dir.path}/tone.wav')..writeAsBytesSync(pcm.takeBytes());
  final out = '${dir.path}/tone.m4a';
  final r = Process.runSync('afconvert', ['-f', 'm4af', '-d', 'aac', '-b', '24000', wav.path, out]);
  if (r.exitCode != 0) return null;
  return File(out).readAsBytesSync();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const system = MethodChannel('ghost_desktop/system');
  late _Recorder rec;
  late Directory dir;

  setUp(() {
    rec = _Recorder();
    dir = Directory.systemTemp.createTempSync('ghost-desk-voice');
    messenger.setMockMethodCallHandler(system, rec.handle);
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(system, null);
    dir.deleteSync(recursive: true);
  });

  group('the recorder (DeskVoice)', () {
    test('a file: no carrier, so five minutes, the Mac told the size that is', () async {
      expect(await DeskVoice.start(), {'ok': true, 'seconds': DeskVoice.fileSeconds});
      expect(rec.calls.single.arguments, {'bytes': DeskVoice.fileBytes});
      // Windows records at 96 kbit/s and says how long fits (desk_sound.cpp): the shorter is what is shown.
      rec.startAnswer = {'ok': true, 'seconds': 80};
      expect((await DeskVoice.start())['seconds'], 80);
    });

    test('a text: the phone\'s carrier says how long and how large', () async {
      expect(await DeskVoice.start(carrier: {'seconds': 91, 'bytes': 299008}), {'ok': true, 'seconds': 91});
      expect(rec.calls.single.arguments, {'bytes': 299008});
      rec.startAnswer = {'ok': true, 'seconds': 24};
      expect((await DeskVoice.start(carrier: {'seconds': 91, 'bytes': 299008}))['seconds'], 24);
    });

    test('refused, or no microphone at all', () async {
      rec.startAnswer = {'ok': false, 'denied': true};
      expect(await DeskVoice.start(), {'ok': false, 'denied': true});
      rec.startAnswer = {'ok': false, 'error': 'There\'s no microphone on this PC'};
      await expectLater(DeskVoice.start(), throwsA(isA<VoiceProblem>().having((e) => '$e', 'words', 'There\'s no microphone on this PC')));
    });

    test('how loud, and the recorder told once it is as long as it may be', () async {
      final full = <void>[];
      final sub = Sms.instance.voiceFull.stream.listen(full.add);
      addTearDown(sub.cancel);
      expect(await DeskVoice.level(), 0.4);
      await Future<void>.delayed(Duration.zero);
      expect(full, isEmpty);
      rec.levelAnswer = {'level': 1.7, 'full': true};
      expect(await DeskVoice.level(), 1.0);
      await Future<void>.delayed(Duration.zero);
      expect(full, hasLength(1));
    });

    test('finished: kept as an .m4a to send, with how long it runs; too short is said', () async {
      final sound = macM4a(dir, 2.5) ?? Uint8List.fromList(List.generate(4096, (i) => i % 7));
      rec.stopAnswer = sound;
      final done = await DeskVoice.finish(into: dir);
      final path = done['path']! as String;
      expect(path, endsWith('.m4a'));
      expect(File(path).readAsBytesSync(), sound);
      if (Platform.isMacOS) expect(done['millis'] as int, inInclusiveRange(2400, 2700));

      rec.stopAnswer = null;
      await expectLater(DeskVoice.finish(into: dir), throwsA(isA<VoiceProblem>().having((e) => '$e', 'words', 'That was too short to send')));
      await DeskVoice.cancel();
      expect(rec.methods.last, 'voiceCancel');
    });
  });

  group('how long a clip runs (m4aMillis)', () {
    Uint8List mvhd({required int version, required int scale, required int length, int before = 40}) {
      final b = BytesBuilder()..add(Uint8List(before));
      final box = ByteData(version == 1 ? 40 : 28);
      // size, 'mvhd', version and flags, the times, timescale, duration.
      box.setUint32(0, box.lengthInBytes);
      'mvhd'.codeUnits.asMap().forEach((i, c) => box.setUint8(4 + i, c));
      box.setUint8(8, version);
      if (version == 1) {
        box.setUint32(28, scale);
        box.setUint32(32, length ~/ 0x100000000);
        box.setUint32(36, length % 0x100000000);
      } else {
        box.setUint32(20, scale);
        box.setUint32(24, length);
      }
      b.add(box.buffer.asUint8List());
      return b.takeBytes();
    }

    test('read from the movie header, either version, wherever it is', () {
      expect(m4aMillis(mvhd(version: 0, scale: 16000, length: 16000 * 7 + 8000)), 7500);
      expect(m4aMillis(mvhd(version: 1, scale: 1000, length: 65000, before: 2000)), 65000);
      expect(m4aMillis(Uint8List.fromList('#!AMR\n'.codeUnits)), 0, reason: 'an AMR from another phone says nothing');
      expect(m4aMillis(Uint8List(0)), 0);
      expect(m4aMillis(mvhd(version: 0, scale: 0, length: 10)), 0);
      final cut = mvhd(version: 0, scale: 1000, length: 10);
      expect(m4aMillis(Uint8List.sublistView(cut, 0, cut.length - 6)), 0, reason: 'cut short');
    });

    test('a real clip from the Mac\'s AAC encoder, as a phone\'s is', () {
      final sound = macM4a(dir, 3.2);
      if (sound == null) return markTestSkipped('needs a Mac');
      expect(m4aMillis(sound), inInclusiveRange(3100, 3400));
    });
  });

  group('the calls that answer the screens', () {
    test('a computer of its own records a file with its own microphone and keeps it', () async {
      final calls = StandaloneCalls(Directory('${dir.path}/standalone'), keychain: false);
      rec.stopAnswer = Uint8List.fromList(List.generate(2048, (i) => i % 5));
      expect(await calls.invokeMethod<Map>('voiceStart', {'file': true}), {'ok': true, 'seconds': DeskVoice.fileSeconds});
      expect(await calls.invokeMethod<double>('voiceLevel'), 0.4);
      final done = (await calls.invokeMethod<Map>('voiceFinish'))!;
      expect(File(done['path'] as String).readAsBytesSync(), rec.stopAnswer);
      File(done['path'] as String).deleteSync();
      expect(rec.methods, ['voiceStart', 'voiceLevel', 'voiceStop']);
    });

    test('startVoice says when it is for a file, and only then', () async {
      final was = Sms.calls;
      final fake = _Calls();
      Sms.calls = fake;
      addTearDown(() => Sms.calls = was);
      expect(await Sms.instance.startVoice(file: true), 300);
      expect(await Sms.instance.startVoice(), 300);
      expect([for (final a in fake.asked) a.$1], ['voiceStart', 'voiceStart']);
      expect(fake.asked[0].$2, {'file': true});
      expect(fake.asked[1].$2, isNull);
      // A computer with a recorder offers the microphone (this one is a Mac or a test machine like one).
      if (Platform.isMacOS || Platform.isWindows) expect(Sms.canRecordVoice, isTrue);
      if (Platform.isLinux) expect(Sms.canRecordVoice, isFalse);
    });
  });

  test('a voice message to a space goes as its file marked a voice message, and comes back one', () {
    final file = SpaceFile(
      id: NetCrypto.hex(NetCrypto.randomBytes(16)),
      name: 'voice-1763850000000.m4a',
      size: 30000,
      mime: 'audio/mp4',
      sha: '',
      key: NetCrypto.randomBytes(32),
      prefix: NetCrypto.randomBytes(8),
      by: 'mac',
      byName: 'Me',
      at: 0,
    );
    final sent = HangoutMessage(id: 'v1', from: 'mac', name: 'Me', text: '', at: 1763850000000, files: [file], voice: true);
    final wire = sent.toJson();
    expect(wire['vo'], 1);
    final heard = HangoutMessage.fromJson(Map<String, dynamic>.from(wire), 'mac')!;
    expect(heard.voice, isTrue);
    expect(heard.files.single.name, 'voice-1763850000000.m4a');
    expect(heard.files.single.size, 30000);
    // A file with words beside it, or two files, is not a voice message.
    final two = HangoutMessage(id: 'v2', from: 'mac', name: 'Me', text: '', at: 1, files: [file, file], voice: true).toJson();
    expect(HangoutMessage.fromJson(Map<String, dynamic>.from(two), 'mac')!.voice, isFalse);
  });

  group('the recorder\'s row', () {
    setUp(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
      messenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => call.method == 'voiceLevel' ? 0.3 : null);
    });

    testWidgets('on a computer the keyboard does it too: Escape throws it away, Enter sends it', (tester) async {
      final sheet = await loadSheet(tester);
      var discarded = 0, sent = 0;
      await pumpScreen(tester, sheet, Column(children: [const Spacer(), VoiceRecorder(limit: 300, onDiscard: () => discarded++, onSend: () => sent++, carrier: false)]), AppState());
      await tester.pump(const Duration(milliseconds: 50));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(discarded, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(sent, 1);
      expect(find.text('5:00'), findsOneWidget, reason: 'the most it may run');
      // Full: a file's recorder says no carrier.
      Sms.instance.voiceFull.add(null);
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('That\'s as long as a voice message can be.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 200));
    });
  });
}
