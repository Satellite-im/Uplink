import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/plugins/voice_changer.dart';
import 'package:ghost_messaging/kit/settings_kit.dart';
import 'package:ghost_messaging/ui/common.dart';
import 'package:ghost_messaging/ui/voice.dart';
import 'package:ghost_messaging/ui/voice_changer_ui.dart';
import 'package:ghost_messaging/voice/voice_changer.dart';

import 'support/space_call_harness.dart';

/// The Voice changer plugin (Matt, 2026-11-20: "build it as a plugin"): lib/voice/voice_changer.dart,
/// lib/plugins/voice_changer.dart, lib/ui/voice_changer_ui.dart. ElevenLabs stood in for by a server here that keeps
/// what it was asked. Pictures: test/shots/voice-changer-* (--update-goldens).
class _Eleven {
  late HttpServer server;
  final asked = <String>[];
  final keys = <String?>[];
  String body = '';
  List<int> upload = const [];
  int status = 200;
  Map<String, Object?>? refusal;
  List<Map<String, Object?>> voices = [
    {'voice_id': '21m00Tcm4TlvDq8ikWAM', 'name': 'Rachel', 'category': 'premade', 'labels': {'gender': 'female', 'age': 'young', 'accent': 'american'}, 'preview_url': 'https://example.test/rachel.mp3'},
    {'voice_id': 'pNInz6obpgDQGcFmaJgB', 'name': 'Adam', 'category': 'premade', 'labels': {'gender': 'male', 'age': 'middle_aged'}, 'preview_url': 'http://not-secure.test/adam.mp3'},
    {'voice_id': 'bad id!', 'name': 'Nope'},
  ];

  Uri get base => Uri.parse('http://127.0.0.1:${server.port}');

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      asked.add('${req.method} ${req.uri.path}${req.uri.query.isEmpty ? '' : '?${req.uri.query}'}');
      keys.add(req.headers.value('xi-api-key'));
      final bytes = await req.fold<List<int>>([], (a, b) => a..addAll(b));
      final res = req.response;
      if (req.headers.value('xi-api-key') != 'sk_good_key_1234') {
        res.statusCode = 401;
        res.write(jsonEncode({'detail': {'status': 'invalid_api_key', 'message': 'Invalid API key'}}));
      } else if (refusal != null) {
        res.statusCode = status;
        res.write(jsonEncode({'detail': refusal}));
      } else if (req.uri.path == '/v2/voices') {
        res.write(jsonEncode({'voices': voices, 'has_more': false}));
      } else if (req.uri.path.startsWith('/v1/voice-changer/')) {
        body = latin1.decode(bytes);
        upload = bytes;
        res.headers.contentType = ContentType('audio', 'mpeg');
        res.add(List.filled(4000, 0x55));
      } else {
        res.statusCode = 404;
      }
      await res.close();
    });
  }
}

void main() {
  late Directory dir;
  late _Eleven eleven;
  final wasOverrides = HttpOverrides.current;
  setUp(() async {
    // The test binding answers every request with 400 unless told not to.
    HttpOverrides.global = null;
    dir = Directory.systemTemp.createTempSync('ghost-voice-changer');
    eleven = _Eleven();
    await eleven.start();
  });
  tearDown(() async {
    HttpOverrides.global = wasOverrides;
    await eleven.server.close(force: true);
    dir.deleteSync(recursive: true);
  });

  test('a key is tried before it is kept; a voice is chosen; a recording goes up whole and comes back in that voice', () async {
    final c = VoiceChanger.forTest(folder: '${dir.path}/store', base: eleven.base, isOn: () => true);
    expect(c.ready, isFalse);
    expect(c.note, isNull);

    expect(await c.setKey('  '), contains('Paste'));
    expect(await c.setKey('two words'), contains('doesn\'t look like'));
    expect(eleven.asked, isEmpty, reason: 'nothing asked of ElevenLabs for what is plainly no key');
    expect(await c.setKey('sk_wrong'), contains('didn\'t accept that key'));
    expect(c.hasKey, isFalse);

    expect(await c.setKey(' sk_good_key_1234 '), isNull);
    expect(c.hasKey, isTrue);
    expect(c.keyEnd, '1234');
    expect([for (final v in c.voices) v.name], ['Rachel', 'Adam'], reason: 'one with an id that is no id is left out');
    expect(c.voices.first.about, 'female · young · american');
    expect(c.voices.first.preview, 'https://example.test/rachel.mp3');
    expect(c.voices[1].preview, isNull, reason: 'a sample not over https is not played');
    expect(c.voices[1].about, 'male · middle aged');
    expect(c.active, isFalse, reason: 'no voice chosen yet');

    c.choose(c.voices.first);
    expect(c.active, isTrue);
    expect(c.note, contains('Rachel'));
    expect(c.note, contains('ElevenLabs'));

    final rec = File('${dir.path}/voice-20261120-101500.m4a')..writeAsBytesSync([for (var i = 0; i < 3000; i++) i % 251]);
    eleven.asked.clear();
    final out = await c.forSending(rec.path);
    expect(out, '${dir.path}/voice-20261120-101500-changed.mp3');
    expect(File(out).lengthSync(), 4000);
    expect(rec.existsSync(), isFalse, reason: 'the recording in the person\'s own voice is let go');
    expect(eleven.asked, ['POST /v1/voice-changer/21m00Tcm4TlvDq8ikWAM?output_format=mp3_44100_64']);
    expect(eleven.keys.last, 'sk_good_key_1234');
    expect(eleven.body, contains('name="model_id"\r\n\r\neleven_multilingual_sts_v2'));
    expect(eleven.body, contains('name="remove_background_noise"\r\n\r\ntrue'));
    expect(eleven.body, contains('name="audio"; filename="voice-20261120-101500.m4a"'));
    // The recording itself, byte for byte, inside the form.
    final at = eleven.body.indexOf('application/octet-stream\r\n\r\n') + 'application/octet-stream\r\n\r\n'.length;
    expect(eleven.upload.sublist(at, at + 3000), [for (var i = 0; i < 3000; i++) i % 251]);

    // Kept for the next run, in a file of the person's own; the key is in no other place.
    final again = VoiceChanger.forTest(folder: '${dir.path}/store', base: eleven.base, isOn: () => true);
    expect(again.keyEnd, '1234');
    expect(again.voice!.name, 'Rachel');
    expect(again.voices.length, 2);
    final kept = File('${dir.path}/store/elevenlabs.json');
    if (!Platform.isWindows) expect(kept.statSync().modeString(), 'rw-------');

    // Its own voice for a while: nothing is asked, and the recording goes as it is.
    again.setPaused(true);
    final own = File('${dir.path}/own.m4a')..writeAsBytesSync(List.filled(500, 1));
    eleven.asked.clear();
    expect(await again.forSending(own.path), own.path);
    expect(own.existsSync(), isTrue);
    expect(eleven.asked, isEmpty);
    expect(again.note, isNull);
    again.setPaused(false);

    // The plugin taken off: likewise.
    final off = VoiceChanger.forTest(folder: '${dir.path}/store', base: eleven.base, isOn: () => false);
    expect(await off.forSending(own.path), own.path);
    expect(eleven.asked, isEmpty);

    // Forgotten: the file goes, and with it the key.
    again.forget();
    expect(kept.existsSync(), isFalse);
    expect(again.hasKey, isFalse);
    expect(VoiceChanger.forTest(folder: '${dir.path}/store', base: eleven.base, isOn: () => true).ready, isFalse);
  });

  test('a recording that could not be changed is never sent as it was', () async {
    final c = VoiceChanger.forTest(folder: '${dir.path}/store', base: eleven.base, isOn: () => true);
    expect(await c.setKey('sk_good_key_1234'), isNull);
    c.choose(c.voices.first);
    Future<String> tried(Map<String, Object?> refusal, int status) async {
      final rec = File('${dir.path}/voice.m4a')..writeAsBytesSync(List.filled(800, 3));
      eleven
        ..refusal = refusal
        ..status = status;
      try {
        await c.forSending(rec.path);
        fail('it was sent');
      } on VoiceChangerProblem catch (e) {
        expect(rec.existsSync(), isFalse, reason: 'let go, not left to be sent some other way');
        expect(File('${dir.path}/voice-changed.mp3').existsSync(), isFalse);
        return e.words;
      }
    }

    expect(await tried({'status': 'quota_exceeded', 'message': 'You have 12 credits left'}, 401), contains('nothing left this month'));
    expect(await tried({'status': 'voice_not_found', 'message': 'no'}, 400), contains('Choose another'));
    expect(await tried({'status': 'too_many_concurrent_requests', 'message': 'busy'}, 429), contains('Try again'));
    expect(await tried({'status': 'something_new', 'message': 'The audio is too short.'}, 400), 'ElevenLabs: The audio is too short.');
    expect(await tried({'status': 'something_new', 'message': 'x' * 400}, 500), contains('error 500'));

    // ElevenLabs out of reach.
    await eleven.server.close(force: true);
    final rec = File('${dir.path}/voice.m4a')..writeAsBytesSync(List.filled(800, 3));
    await expectLater(c.forSending(rec.path), throwsA(isA<VoiceChangerProblem>().having((e) => e.words, 'words', contains('Couldn\'t reach ElevenLabs'))));
    expect(rec.existsSync(), isFalse);
    await eleven.start();
  });

  test('the plugin: for this device alone, off until added, with a section of its own in Settings', () {
    const p = VoiceChangerPlugin();
    expect(shippedPlugins.whereType<VoiceChangerPlugin>().length, 1);
    expect(p.scopes, {PluginScope.device});
    expect(p.onByDefault, isFalse);
    expect(p.settingsPage, isNotNull);
    expect(p.reaches.map((r) => r.label).join(' '), contains('ElevenLabs'), reason: 'what leaves the device is said before it is added');
  });

  testWidgets('its rows in Settings, the key\'s page and the voices; the recorder says whose voice it goes in', (tester) async {
    final h = await SpaceHarness.load(tester);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => null);
    HttpOverrides.global = null;
    final c = VoiceChanger.instance
      ..folder = '${dir.path}/ui'
      ..base = eleven.base
      ..isOn = (() => true);
    addTearDown(() {
      c
        ..forget()
        ..folder = null
        ..base = Uri.parse('https://api.elevenlabs.io')
        ..isOn = VoiceChangerPlugin.isOn;
    });
    Widget page() => GhostPage(
          title: 'Voice changer',
          body: SettingsPaneScope(
            finder: SettingsFinder(),
            child: ListView(padding: const EdgeInsets.all(16), children: const [
              PaneSection(children: [VoiceChangerKeyRow(), VoiceChangerVoiceRow(), VoiceChangerOnRow(), VoiceChangerLiveRow(), VoiceChangerCleanRow(), VoiceChangerForgetRow()]),
            ]),
          ),
        );
    await h.shoot(tester, page(), 'voice-changer-empty');
    expect(find.text('Add'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('changer-key')));
    await h.again(tester, 'voice-changer-key');
    await tester.enterText(find.byType(EditableText), 'sk_wrong');
    await tester.pump();
    // Pressed where real time runs, so the request it makes is a real one to the server here.
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('changer-key-save')));
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('changer-key-problem')), findsOneWidget);
    expect(c.hasKey, isFalse);

    await tester.enterText(find.byType(EditableText), 'sk_good_key_1234');
    await tester.pump();
    // Pressed where real time runs, so the request it makes is a real one to the server here.
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('changer-key-save')));
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await h.again(tester, 'voice-changer-voices');
    expect(find.text('Rachel'), findsOneWidget);
    expect(find.text('female · young · american'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('changer-voice-21m00Tcm4TlvDq8ikWAM')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.voice!.name, 'Rachel');
    expect(c.active, isTrue);
    await tester.pump(const Duration(seconds: 7));
    await h.again(tester, 'voice-changer-set');
    expect(find.text('Ends in 1234'), findsOneWidget);
    expect(find.text('sk_good_key_1234'), findsNothing, reason: 'the key is never shown again');

    // The composer while recording: whose voice it goes in, and where the recording goes.
    await h.shoot(tester, GhostPage(title: 'Lounge', body: Column(children: [const Spacer(), VoiceRecorder(limit: 60, onDiscard: () {}, onSend: () {}, note: c.note)])), 'voice-changer-recording', dark: true);
    expect(find.textContaining('Sent in Rachel\'s voice'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
