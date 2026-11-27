import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/ui/video_engine.dart';
import 'package:ghost_messaging/ui/video_screen.dart';
import 'package:ghost_messaging/ui/video_tracks.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart' as vpi;

import 'support/fake_video.dart';
import 'support/list_harness.dart';

/// Choosing a video's sound and subtitles (lib/ui/video_tracks.dart, lib/ui/video_screen.dart; Matt, 2026-11-18: "on
/// the video player add support for switching audio and subtitles for files that support dual languages"): how tracks
/// are named, which one the languages last chosen pick, the panel in the player's dock, and the phone's engine.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const english = MediaTrack(id: '1', kind: TrackKind.audio, language: 'eng');
  const japanese = MediaTrack(id: '2', kind: TrackKind.audio, language: 'jpn', title: 'Japanese');
  const commentary = MediaTrack(id: '3', kind: TrackKind.audio, language: 'en', title: 'Director\'s commentary');
  const subEnglish = MediaTrack(id: '1', kind: TrackKind.subtitle, language: 'en');
  const subSpanish = MediaTrack(id: '2', kind: TrackKind.subtitle, language: 'spa', title: 'Latin American');

  group('naming', () {
    test('languages are one code however the file writes them', () {
      expect(normalLanguage('eng'), 'en');
      expect(normalLanguage('en-US'), 'en');
      expect(normalLanguage('fre'), 'fr');
      expect(normalLanguage('fra'), 'fr');
      expect(normalLanguage('pt_BR'), 'pt');
      expect(normalLanguage('und'), isNull);
      expect(normalLanguage(''), isNull);
      expect(normalLanguage(null), isNull);
      expect(languageName('jpn'), 'Japanese');
      expect(languageName('xx'), 'XX');
      expect(knownLanguage('forced'), isFalse);
      expect(knownLanguage('es'), isTrue);
    });

    test('a track is called by its language and title; one that says neither by its place; shared names numbered', () {
      expect(
        trackLabels(const [english, japanese, commentary, MediaTrack(id: '4', kind: TrackKind.audio), MediaTrack(id: '5', kind: TrackKind.audio, language: 'en-GB')]),
        ['English 1', 'Japanese', 'English · Director\'s commentary', 'Track 4', 'English 2'],
      );
      expect(trackLabels(const [MediaTrack(id: '9', kind: TrackKind.subtitle, title: 'Signs & songs')]), ['Signs & songs']);
    });

    test('the first track in a language', () {
      expect(trackIn(const [english, japanese, commentary], 'ja'), japanese);
      expect(trackIn(const [english, japanese], 'en-US'), english);
      expect(trackIn(const [english, japanese], 'de'), isNull);
      expect(trackIn(const [english], null), isNull);
    });
  });

  group('memory', () {
    late Map<String, String> kept;
    late TrackMemory memory;
    setUp(() {
      kept = {};
      memory = TrackMemory(read: (k) => kept[k] ?? '', write: (k, v) => kept[k] = v);
    });

    test('nothing chosen yet: the file\'s own choice stays', () {
      expect(memory.plan(const VideoTracks(audio: [english, japanese], audioOn: '1', subtitles: [subEnglish])).isEmpty, isTrue);
    });

    test('the sound and subtitles last chosen are picked in the next file', () {
      memory.choseAudio(japanese);
      memory.choseSubtitle(subSpanish);
      expect(kept, {TrackMemory.audioKey: 'ja', TrackMemory.subtitleKey: 'es'});
      expect(
        memory.plan(const VideoTracks(audio: [english, japanese], audioOn: '1', subtitles: [subEnglish, subSpanish])),
        const TrackPlan(audio: '2', subtitle: '2'),
      );
    });

    test('already playing what was chosen, or nothing in that language: nothing changes', () {
      kept[TrackMemory.audioKey] = 'ja';
      kept[TrackMemory.subtitleKey] = 'de';
      expect(memory.plan(const VideoTracks(audio: [english, japanese], audioOn: '2', subtitles: [subEnglish])).isEmpty, isTrue);
      kept[TrackMemory.audioKey] = 'ko';
      expect(memory.plan(const VideoTracks(audio: [english, japanese], audioOn: '1')).isEmpty, isTrue);
      // The engine hasn't said which sound plays: the first is taken as playing.
      kept[TrackMemory.audioKey] = 'en';
      expect(memory.plan(const VideoTracks(audio: [english, japanese])).isEmpty, isTrue);
    });

    test('subtitles turned off stay off in the next file', () {
      memory.choseSubtitle(null);
      expect(kept[TrackMemory.subtitleKey], TrackMemory.off);
      expect(memory.plan(const VideoTracks(subtitles: [subEnglish], subtitleOn: '1')), const TrackPlan(subtitlesOff: true));
      expect(memory.plan(const VideoTracks(subtitles: [subEnglish])).isEmpty, isTrue, reason: 'already off');
    });

    test('a track that says no language keeps what was kept', () {
      memory.choseAudio(english);
      memory.choseAudio(const MediaTrack(id: '7', kind: TrackKind.audio, language: 'und'));
      expect(kept[TrackMemory.audioKey], 'en');
    });
  });

  test('subtitle files beside a video are found, with the language in their names', () async {
    final dir = await Directory.systemTemp.createTemp('tracks');
    addTearDown(() => dir.delete(recursive: true));
    for (final n in ['Film.mkv', 'Film.srt', 'Film.es.srt', 'Film.forced.vtt', 'Film.en.ass', 'Other.srt', 'Film.txt']) {
      File('${dir.path}/$n').writeAsStringSync('');
    }
    final found = await subtitleFilesBeside('${dir.path}/Film.mkv');
    expect(found.map((t) => t.title), ['Film.en.ass', 'Film.es.srt', 'Film.forced.vtt', 'Film.srt']);
    expect(found.map((t) => t.language), ['en', 'es', null, null]);
    expect(found.every((t) => t.external && t.kind == TrackKind.subtitle), isTrue);
    final phone = await subtitleFilesBeside('${dir.path}/Film.mkv', extensions: const ['srt', 'vtt']);
    expect(phone.map((t) => t.title), ['Film.es.srt', 'Film.forced.vtt', 'Film.srt']);
  });

  group('the player', () {
    late FakeVideoEngine engine;
    final prefs = <String, String>{};
    const sms = MethodChannel('ghost_messaging/sms');

    setUp(() {
      prefs.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(sms, (call) async {
        if (call.method == 'setPref') {
          final a = call.arguments as Map;
          prefs['${a['key']}'] = '${a['value']}';
        }
        if (call.method == 'prefs') return Map<String, String>.of(prefs);
        return null;
      });
    });
    tearDown(() {
      VideoEngine.make = VideoEngine.defaultEngine;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(sms, null);
    });

    Future<AppState> open(WidgetTester tester, VideoTracks tracks, {Map<String, String> kept = const {}, Size size = const Size(1100, 700)}) async {
      engine = FakeVideoEngine(still: true, tracks: tracks);
      VideoEngine.make = () => engine;
      prefs.addAll(kept);
      final state = AppState();
      await state.load();
      final sheet = await loadSheet(tester);
      await pumpScreen(tester, sheet, const VideoScreen(path: '/tmp/film.mkv', title: 'Film', desk: true), state, size: size);
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump(const Duration(milliseconds: 50));
      return state;
    }

    /// The row called [words] (the first of two alike: the sound's before the subtitles'), marked as on or not.
    void row(WidgetTester tester, String words, {required bool on}) {
      expect(tester.getSemantics(find.bySemanticsLabel(words).first), isSemantics(label: words, isSelected: on));
    }

    Future<void> close(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('one sound and no subtitles: no button', (tester) async {
      await open(tester, const VideoTracks(audio: [english], audioOn: '1'));
      expect(find.bySemanticsLabel('Audio and subtitles'), findsNothing);
      await close(tester);
    });

    testWidgets('the dock\'s button lists the sounds and subtitles, marks those on, and switches them', (tester) async {
      final state = await open(tester, const VideoTracks(audio: [english, japanese], audioOn: '1', subtitles: [subEnglish, subSpanish]));
      await tester.tap(find.bySemanticsLabel('Audio and subtitles'));
      await tester.pump();
      expect(find.text('AUDIO'), findsOneWidget);
      expect(find.text('SUBTITLES'), findsOneWidget);
      row(tester, 'English', on: true);
      row(tester, 'Japanese', on: false);
      row(tester, 'Off', on: true);
      row(tester, 'Spanish · Latin American', on: false);

      await tester.tap(find.bySemanticsLabel('Japanese'));
      await tester.pump();
      expect(engine.calls, contains('audio 2'));
      expect(find.text('AUDIO'), findsNothing, reason: 'the list goes once a track is chosen');
      expect(state.choice(TrackMemory.audioKey, ''), 'ja');

      await tester.tap(find.bySemanticsLabel('Audio and subtitles'));
      await tester.pump();
      row(tester, 'Japanese', on: true);
      row(tester, 'English', on: false);
      await tester.tap(find.bySemanticsLabel('Spanish · Latin American'));
      await tester.pump();
      expect(engine.calls, contains('subtitle 2'));
      expect(state.choice(TrackMemory.subtitleKey, ''), 'es');

      await tester.tap(find.bySemanticsLabel('Audio and subtitles'));
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Off'));
      await tester.pump();
      expect(engine.calls.last, 'subtitle off');
      expect(state.choice(TrackMemory.subtitleKey, ''), TrackMemory.off);
      await close(tester);
    });

    testWidgets('Esc and a tap on the picture put the list away before anything else', (tester) async {
      await open(tester, const VideoTracks(audio: [english, japanese], audioOn: '1'));
      await tester.tap(find.bySemanticsLabel('Audio and subtitles'));
      await tester.pump();
      expect(find.text('AUDIO'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('AUDIO'), findsNothing);
      expect(find.byType(VideoScreen), findsOneWidget, reason: 'still here: Esc closed only the list');
      await tester.tap(find.bySemanticsLabel('Audio and subtitles'));
      await tester.pump();
      await tester.tapAt(const Offset(550, 300));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('AUDIO'), findsNothing);
      await close(tester);
    });

    testWidgets('the next file opens in the languages last chosen', (tester) async {
      await open(
        tester,
        const VideoTracks(audio: [english, japanese], audioOn: '1', subtitles: [subEnglish, subSpanish]),
        kept: {TrackMemory.audioKey: 'ja', TrackMemory.subtitleKey: 'es'},
      );
      expect(engine.calls, containsAll(['audio 2', 'subtitle 2']));
      await close(tester);
    });

    testWidgets('on a phone the button sits in the dock too', (tester) async {
      engine = FakeVideoEngine(still: true, tracks: const VideoTracks(audio: [english, japanese], audioOn: '1', innerSubtitles: false));
      VideoEngine.make = () => engine;
      final sheet = await loadSheet(tester);
      await pumpScreen(tester, sheet, const VideoScreen(path: '/tmp/film.mkv', desk: false), AppState());
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.bySemanticsLabel('Audio and subtitles'));
      await tester.pump();
      expect(find.text('Subtitles inside a video can\'t be shown on this device yet.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await close(tester);
    });
  });

  // Real time, not a widget test's: the engine reads the folder beside the file.
  test('the phone\'s engine lists ExoPlayer\'s sounds and chooses one', () async {
    final fake = FakeVideoPlayer(audioTracks: const [
      vpi.VideoAudioTrack(id: '0:0', label: null, language: 'en', isSelected: true),
      vpi.VideoAudioTrack(id: '0:1', label: 'Commentary', language: 'es', isSelected: false),
    ]);
    vpi.VideoPlayerPlatform.instance = fake;
    final engine = VideoPlayerEngine();
    final dir = await Directory.systemTemp.createTemp('phone');
    addTearDown(() => dir.delete(recursive: true));
    File('${dir.path}/clip.en.srt').writeAsStringSync('1\n00:00:01,000 --> 00:00:02,000\nHello\n');
    await engine.open('${dir.path}/clip.mp4');
    for (var i = 0; i < 100 && engine.value.tracks.audio.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final tracks = engine.value.tracks;
    expect(tracks.audio.map((t) => (t.id, t.language, t.title)), [('0:0', 'en', null), ('0:1', 'es', 'Commentary')]);
    expect(tracks.audioOn, '0:0');
    expect(tracks.innerSubtitles, isFalse, reason: 'video_player shows no subtitles carried inside a file');
    expect(tracks.subtitles.map((t) => (t.language, t.title)), [('en', 'clip.en.srt')], reason: 'a subtitle file beside it is offered');
    await engine.chooseAudio('0:1');
    expect(fake.calls, contains('audio 0:1'));
    expect(engine.value.tracks.audioOn, '0:1');
    // The controller says something new (it plays): the tracks and the choice are still there after.
    await engine.play();
    expect(engine.value.playing, isTrue);
    expect(engine.value.tracks.audio.map((t) => t.id), ['0:0', '0:1'], reason: 'a tick of the controller doesn\'t empty the list');
    expect(engine.value.tracks.audioOn, '0:1');
    expect(engine.value.tracks.subtitles, hasLength(1));
    await engine.release();
    engine.dispose();
  });
}
