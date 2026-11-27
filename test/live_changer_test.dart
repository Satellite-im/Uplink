import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/voice/live_changer.dart';
import 'package:ghost_messaging/voice/voice_changer.dart';

/// The voice changer live in a space's call (lib/voice/live_changer.dart; Matt, 2026-11-20: "I'd like the voice changer
/// to work in spaces calles in real time", ElevenLabs chosen with its delay). The microphone engine's half is
/// native/voicefx/test (voicefx_live, take, feed).

/// [ms] of 16 kHz 16-bit mono: speech (a 220 Hz tone at [level]) or silence.
Uint8List sound(int ms, {double level = 6000}) {
  final n = 16 * ms;
  final b = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    b.setInt16(i * 2, (level * math.sin(i * 2 * math.pi * 220 / 16000)).round(), Endian.little);
  }
  return b.buffer.asUint8List();
}

Uint8List join(List<Uint8List> parts) => Uint8List.fromList([for (final p in parts) ...p]);

void main() {
  group('PhraseCutter', () {
    test('a phrase is cut at the pause after it, with a little from before it began', () {
      final c = PhraseCutter();
      expect(c.add(sound(500, level: 0)), isEmpty, reason: 'silence is no phrase');
      expect(c.add(sound(1000)), isEmpty, reason: 'still talking');
      final got = c.add(sound(700, level: 0));
      expect(got, hasLength(1));
      // 250 ms before, the second of speech, and the 550 ms pause that ended it.
      expect(got.single.length ~/ 2, closeTo(16 * (250 + 1000 + 550), 16 * 25));
    });

    test('talk that goes on is cut every four seconds, so nobody waits for the end of a speech', () {
      final c = PhraseCutter();
      final got = c.add(sound(9000));
      expect(got, hasLength(2));
      for (final p in got) {
        expect(p.length ~/ 2, closeTo(16 * 4000, 16 * 40));
      }
    });

    test('a click or a cough shorter than a quarter second is not sent', () {
      final c = PhraseCutter();
      expect(c.add(join([sound(100), sound(800, level: 0)])), isEmpty);
    });
  });

  test('a phrase goes up as a WAV file ElevenLabs can read', () {
    final w = LiveChanger.wav(sound(100), 16000);
    final h = ByteData.sublistView(w);
    expect(ascii.decode(w.sublist(0, 4)), 'RIFF');
    expect(ascii.decode(w.sublist(8, 16)), 'WAVEfmt ');
    expect(h.getUint32(24, Endian.little), 16000);
    expect(h.getUint16(34, Endian.little), 16);
    expect(h.getUint32(40, Endian.little), 3200);
    expect(w.length, 44 + 3200);
  });

  group('LiveChanger', () {
    late List<Uint8List> toTake;
    late List<(int, int)> fed;
    late List<int> converted;
    late List<bool> liveSaid;
    late List<String> effects;
    var run = true, muted = false;
    var way = CallVoiceWay.elevenlabs;
    var effect = VoiceEffect.deeper;
    Object? refuse;

    LiveChanger make() => LiveChanger(
          take: ({int most = 32000}) async => toTake.isEmpty ? Uint8List(0) : toTake.removeAt(0),
          feed: (pcm, rate) async {
            fed.add((pcm.length, rate));
            return 0;
          },
          setLive: (on) async {
            liveSaid.add(on);
            return true;
          },
          convert: (wav) async {
            converted.add(wav.length);
            if (refuse != null) throw refuse!;
            return Uint8List(4800);
          },
          setEffect: (name) async {
            effects.add(name);
            return true;
          },
          shouldRun: () => run,
          muted: () => muted,
          way: () => way,
          effect: () => effect,
        );

    setUp(() {
      toTake = [];
      fed = [];
      converted = [];
      liveSaid = [];
      effects = [];
      way = CallVoiceWay.elevenlabs;
      effect = VoiceEffect.deeper;
      run = true;
      muted = false;
      refuse = null;
    });

    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    // Matt, 2026-11-21: "Add support (by default) for the voice changer to use on the fly voice changing the
    // elevenlabs is very slow and not real time".
    test('on this device: the effect is switched on in the microphone engine, nothing is taken or sent, and it follows the choice', () async {
      way = CallVoiceWay.device;
      final live = make();
      await live.follow();
      expect(effects, ['deeper']);
      expect(liveSaid, [false], reason: 'the voice goes into the call, changed as it goes: nothing held back');
      expect(live.on, isTrue);
      expect(live.effect, VoiceEffect.deeper);
      toTake = [sound(1200), sound(700, level: 0)];
      await live.readOnce();
      await settle();
      expect(converted, isEmpty, reason: 'nothing goes to ElevenLabs');
      effect = VoiceEffect.robot;
      await live.follow();
      expect(effects, ['deeper', 'robot']);
      // Over to ElevenLabs in the call: the effect off, the phrases on.
      way = CallVoiceWay.elevenlabs;
      await live.follow();
      expect(effects.last, 'none');
      expect(liveSaid.last, isTrue);
      expect(live.effect, isNull);
      run = false;
      await live.follow();
      expect(effects.last, 'none');
      expect(liveSaid.last, isFalse);
      expect(live.on, isFalse);
      live.dispose();
    });

    test('what is said goes to ElevenLabs a phrase at a time, and what comes back is played into the call', () async {
      final live = make();
      await live.follow();
      expect(liveSaid, [true]);
      toTake = [sound(1200), sound(700, level: 0)];
      await live.readOnce();
      await live.readOnce();
      await settle();
      expect(converted, hasLength(1));
      expect(fed.single, (4800, VoiceChanger.liveRate));
      expect(live.problem, isNull);
      expect(live.behind, greaterThan(Duration.zero));
      run = false;
      await live.follow();
      expect(liveSaid, [true, false], reason: 'off: the microphone goes into the call again');
      live.dispose();
    });

    test('while muted nothing is sent, and what was said then is let go', () async {
      final live = make();
      await live.follow();
      muted = true;
      toTake = [sound(1200)];
      await live.readOnce();
      muted = false;
      toTake = [sound(700, level: 0)];
      await live.readOnce();
      await settle();
      expect(converted, isEmpty, reason: 'the speech before the pause was said while muted');
      live.dispose();
    });

    test('refused by ElevenLabs: nothing of the voice goes out, and the line says why', () async {
      final live = make();
      await live.follow();
      refuse = const VoiceChangerProblem('Your ElevenLabs plan has nothing left this month for a recording this long.');
      toTake = [sound(1200), sound(700, level: 0)];
      await live.readOnce();
      await live.readOnce();
      await settle();
      expect(converted, hasLength(1));
      expect(fed, isEmpty, reason: 'never the voice unchanged');
      expect(live.problem, contains('plan has nothing left'));
      live.dispose();
    });
  });

  test('a phrase goes to ElevenLabs\' voice changer as WAV and comes back as raw PCM at 24 kHz', () async {
    final was = HttpOverrides.current;
    HttpOverrides.global = null;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final asked = <String>[];
    var body = '';
    server.listen((req) async {
      asked.add('${req.method} ${req.uri.path}?${req.uri.query}');
      final bytes = await req.fold<List<int>>([], (a, b) => a..addAll(b));
      if (req.uri.path == '/v2/voices') {
        req.response.write(jsonEncode({'voices': [{'voice_id': '21m00Tcm4TlvDq8ikWAM', 'name': 'Rachel', 'category': 'premade'}], 'has_more': false}));
      } else {
        body = latin1.decode(bytes);
        req.response.add(List.filled(4800, 7));
      }
      await req.response.close();
    });
    final dir = Directory.systemTemp.createTempSync('ghost-live-changer');
    addTearDown(() async {
      HttpOverrides.global = was;
      await server.close(force: true);
      dir.deleteSync(recursive: true);
    });
    final c = VoiceChanger.forTest(folder: dir.path, base: Uri.parse('http://127.0.0.1:${server.port}'), isOn: () => true);
    expect(await c.setKey('sk_good_key_1234'), isNull);
    c.choose(c.voices.first);
    c.setLive(true);
    expect(c.liveActive, isTrue);
    final back = await c.convertPhrase(LiveChanger.wav(sound(500), 16000));
    expect(back.length, 4800);
    expect(asked.last, 'POST /v1/voice-changer/21m00Tcm4TlvDq8ikWAM?output_format=pcm_24000');
    expect(body, contains('filename="phrase.wav"'));
    expect(body, contains('eleven_multilingual_sts_v2'));
    expect(VoiceChanger.forTest(folder: dir.path, base: Uri.parse('http://127.0.0.1:${server.port}'), isOn: () => true).live, isTrue, reason: 'kept');
  });
}
