import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/desktop/remote.dart';
import 'package:ghost_messaging/files/file_kinds.dart';
import 'package:ghost_messaging/files/files_model.dart';
import 'package:ghost_messaging/files/files_store.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/ui/files_space/file_preview.dart';
import 'package:ghost_messaging/ui/video_engine.dart';
import 'package:ghost_messaging/ui/video_screen.dart';
import 'package:ghost_messaging/ui/window_chrome.dart' show MacChrome;
import 'package:ghost_messaging/voice/mp4_names.dart';
import 'package:ghost_messaging/voice/recorder.dart';
import 'package:ghost_messaging/voice/recording_playback.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/fake_video.dart';
import 'support/list_harness.dart';

Uint8List _ascii(String s) => Uint8List.fromList(s.codeUnits);

/// An MP4 box of [type] holding [body].
Uint8List _box(String type, List<Uint8List> body) {
  final b = BytesBuilder()
    ..add(Uint8List(4)..buffer.asByteData().setUint32(0, 8 + body.fold<int>(0, (n, x) => n + x.length)))
    ..add(_ascii(type));
  body.forEach(b.add);
  return b.toBytes();
}

/// A sound track as a muxer writes one, enough of it to be named (lib/voice/mp4_names.dart): a header and a handler.
Uint8List _soundTrak() => _box('trak', [
      _box('tkhd', [Uint8List(84)]),
      _box('mdia', [
        _box('hdlr', [Uint8List(8), _ascii('soun'), Uint8List(12), _ascii('SoundHandler'), Uint8List(1)]),
      ]),
    ]);

/// The player's controls over whichever engine plays the video (lib/ui/video_screen.dart, lib/ui/video_engine.dart;
/// Matt, 2026-11-18: "add support for playing mkv video files and mp4's within the app in a player themed by glacier
/// UI"): play and pause, going back and on, the scrubber, the computer's keys, the volume, full screen, a file that
/// can't be played; and an .mkv opened from a Files space on a computer playing in the app, not elsewhere.
void main() {
  late FakeVideoEngine engine;
  final fullscreen = <String>[];

  setUp(() {
    engine = FakeVideoEngine();
    VideoEngine.make = () => engine;
    fullscreen.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('com.alexmercerind/media_kit_video'), (call) async {
      fullscreen.add(call.method);
      return null;
    });
  });
  tearDown(() {
    VideoEngine.make = VideoEngine.defaultEngine;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('com.alexmercerind/media_kit_video'), null);
  });

  /// Opens [screen] and lets the player come in (it is made once the screen has, at most 600 ms on).
  Future<void> open(WidgetTester tester, Widget screen, {Size size = const Size(1100, 700)}) async {
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, screen, AppState(), size: size);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('the dock plays, pauses, seeks and turns the sound; the engine is let go after the screen', (tester) async {
    await open(tester, const VideoScreen(path: '/tmp/clip.mkv', title: 'Maya Chen', desk: true));
    expect(engine.opened, '/tmp/clip.mkv');
    expect(engine.calls, contains('play'), reason: 'it plays as it opens');
    expect(find.text('Maya Chen'), findsOneWidget);
    expect(find.text('0:42'), findsOneWidget);
    expect(find.text('2:40'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Pause'));
    await tester.pump();
    expect(engine.calls.last, 'pause');
    expect(find.bySemanticsLabel('Play'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Play'));
    await tester.pump();
    expect(engine.calls.last, 'play');

    // A click halfway along the scrubber goes to halfway (1:20).
    final scrubber = tester.getRect(find.bySemanticsLabel('Where the video is'));
    await tester.tapAt(scrubber.center);
    await tester.pump();
    expect(engine.calls.last, 'seek 80');
    // Dragged with the mouse to near its end.
    final mouse = await tester.startGesture(scrubber.centerLeft + const Offset(10, 0), kind: PointerDeviceKind.mouse);
    await mouse.moveBy(const Offset(40, 0));
    await mouse.moveTo(scrubber.centerRight - const Offset(2, 0));
    await tester.pump();
    await mouse.up();
    await tester.pump();
    expect(engine.calls.last, startsWith('seek 15'), reason: 'dragged to its end: ${engine.calls.last}');

    await tester.tap(find.bySemanticsLabel('Mute'));
    await tester.pump();
    expect(engine.calls.last, 'volume 0.0');
    await tester.tap(find.bySemanticsLabel('Sound on'));
    await tester.pump();
    expect(engine.calls.last, 'volume 1.0');
    // The volume slider, a computer's: a click at its start is silence.
    final volume = tester.getRect(find.bySemanticsLabel('Volume'));
    await tester.tapAt(volume.centerLeft + const Offset(1, 0));
    await tester.pump();
    expect(engine.calls.last, 'volume 0.0');
    expect(find.bySemanticsLabel('Sound on'), findsOneWidget, reason: 'silence shows as muted');

    await tester.pumpWidget(const SizedBox());
    expect(engine.calls, isNot(contains('release')), reason: 'not while the screen goes');
    await tester.pump(const Duration(milliseconds: 500));
    expect(engine.calls.last, 'release');
  });

  testWidgets('a computer\'s keys: space, the arrows, F and Esc', (tester) async {
    await open(tester, const VideoScreen(path: '/tmp/clip.mp4', desk: true));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(engine.calls.last, 'pause');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(engine.calls.last, 'play');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(engine.calls.last, 'seek 52');
    expect(find.text('+10 s'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(engine.calls.last, 'seek 42');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(engine.calls.last, 'volume 0.9');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pump();
    expect(fullscreen, ['Utils.EnterNativeFullscreen']);
    expect(find.bySemanticsLabel('Leave full screen'), findsOneWidget);
    // Esc leaves full screen, and the video stays (GMFB-65).
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(fullscreen, ['Utils.EnterNativeFullscreen', 'Utils.ExitNativeFullscreen']);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.bySemanticsLabel('Full screen'), findsOneWidget);
    await close(tester);
  });

  // GMFB-65 (Matt, Windows): "When watching a video and hitting fullscreen i expect the video itself to be
  // fullscreend but the whole app is fullscreened and I still see the sidebar". The player opens in the pane beside
  // the list; full screen draws it over the whole window, and Esc or the button puts it back in its pane, the same
  // player still playing.
  testWidgets('full screen on a computer covers the whole window, the list beside the player too', (tester) async {
    final semantics = tester.ensureSemantics();
    await open(
      tester,
      Row(children: [
        const SizedBox(width: 320, child: ColoredBox(color: Color(0xFFEEEEEE), child: Center(child: Text('The list')))),
        Expanded(
          child: Navigator(onGenerateRoute: (_) => PageRouteBuilder<void>(pageBuilder: (context, _, _) => const VideoScreen(path: '/tmp/clip.mp4', title: 'Holiday', desk: true))),
        ),
      ]),
    );
    // The picture's own widget (FakeVideoEngine.view): where the player is drawn.
    Rect picture() => tester.getRect(find.byType(AspectRatio).first);
    expect(picture().left, greaterThanOrEqualTo(320));
    expect(tester.getRect(find.bySemanticsLabel('Full screen')).left, greaterThan(320));
    final made = engine.calls.where((c) => c.startsWith('open')).length;
    await tester.tap(find.bySemanticsLabel('Full screen'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(fullscreen, ['Utils.EnterNativeFullscreen']);
    // The title strip, which stands above the pages and is not under the player, is told to go.
    expect(MacChrome.covered.value, isTrue);
    // 16:9 in a window of 1100 by 700: the whole width, from the window's left edge.
    expect(picture().left, 0);
    expect(picture().width, 1100);
    // The list is under it: a press where the list stands reaches the player (the controls come and go), not the list.
    expect(tester.hitTestOnBinding(const Offset(160, 350)).path.any((e) => e.target is RenderParagraph), isFalse);
    // The same player, not another opened in its place.
    expect(engine.calls.where((c) => c.startsWith('open')).length, made);
    expect(engine.calls.any((c) => c.startsWith('dispose')), isFalse);
    // The keys are still the player's: Esc leaves full screen and the player is back in its pane.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(fullscreen, ['Utils.EnterNativeFullscreen', 'Utils.ExitNativeFullscreen']);
    expect(picture().left, greaterThanOrEqualTo(320));
    expect(MacChrome.covered.value, isFalse);
    expect(find.text('The list').hitTestable(), findsOneWidget);
    // And the button does the same both ways.
    await tester.tap(find.bySemanticsLabel('Full screen'));
    await tester.pump();
    expect(picture().left, 0);
    await tester.tap(find.bySemanticsLabel('Leave full screen'));
    await tester.pump();
    expect(picture().left, greaterThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
    semantics.dispose();
    await close(tester);
  });

  testWidgets('a double tap on the left goes back ten seconds; the controls go by themselves while it plays', (tester) async {
    await open(tester, const VideoScreen(path: '/tmp/clip.mp4', desk: false), size: const Size(412, 892));
    expect(find.bySemanticsLabel('Volume'), findsNothing, reason: 'a phone turns the sound with its own buttons');
    await tester.tapAt(const Offset(80, 446));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(const Offset(80, 446));
    await tester.pump(const Duration(milliseconds: 400));
    expect(engine.calls.last, 'seek 32');
    await tester.pump(const Duration(seconds: 4));
    final opacity = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity).first);
    expect(opacity.opacity, 0, reason: 'hidden after a few seconds of playing');
    await close(tester);
  });

  // Matt, 2026-11-21: "add the ability to full screen videos played from files".
  testWidgets('a phone has full screen too: the bars hidden, turned the way the picture is, and back leaves it first', (tester) async {
    final said = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setEnabledSystemUIMode') said.add('mode ${call.arguments}');
      if (call.method == 'SystemChrome.setEnabledSystemUIOverlays') said.add('bars ${call.arguments}');
      if (call.method == 'SystemChrome.setPreferredOrientations') said.add('turn ${call.arguments}');
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await open(tester, const VideoScreen(path: '/tmp/clip.mp4', title: 'Holiday', desk: false), size: const Size(412, 892));
    engine.value = engine.value.copyWith(aspect: 16 / 9);
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Full screen'));
    await tester.pump();
    expect(said, ['mode SystemUiMode.immersiveSticky', 'turn [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]']);
    expect(find.bySemanticsLabel('Leave full screen'), findsOneWidget);
    expect(fullscreen, isEmpty, reason: 'not the computer\'s window');
    // The back gesture: out of full screen, still on the video.
    said.clear();
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(said.where((w) => w.startsWith('mode') || w.startsWith('bars')), isNotEmpty, reason: 'the bars back');
    expect(said.last, 'turn []');
    expect(find.text('Holiday'), findsOneWidget);
    expect(find.bySemanticsLabel('Full screen'), findsOneWidget);
    // A tall video stays upright.
    engine.value = engine.value.copyWith(aspect: 9 / 16);
    said.clear();
    await tester.tap(find.bySemanticsLabel('Full screen'));
    await tester.pump();
    expect(said.last, 'turn [DeviceOrientation.portraitUp]');
    await close(tester);
  });

  testWidgets('a file that can\'t be played says so, and offers another app', (tester) async {
    engine = FakeVideoEngine(fails: true);
    await open(tester, const VideoScreen(path: '/tmp/clip.mkv', title: 'Maya Chen', desk: true));
    expect(find.text('This video can\'t be played here.'), findsOneWidget);
    expect(find.textContaining('This computer can\'t read'), findsOneWidget);
    expect(find.bySemanticsLabel('Open with another app'), findsOneWidget);
    expect(find.bySemanticsLabel('Play'), findsNothing, reason: 'no dock for what does not play');
    expect(find.bySemanticsLabel('Back'), findsOneWidget);
    await close(tester);
  });

  // Matt, 2026-11-18: an .mkv on a computer used to go to another app (Files) or a window of AVFoundation's, which
  // could not read it (a chat's video). Now both are the app's own player.
  testWidgets('an .mkv from a Files space opens in the app\'s own player', (tester) async {
    final dir = Directory.systemTemp.createTempSync('ghost-video-mkv');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = FilesStore.forTest(base: null, signer: KeysSigner(NetKeys.generate()), data: dir);
    const space = VoiceChannel(seed: '9191919191919191919191919191919191919191919191919191919191919191', name: 'Drop box', kind: SpaceKind.files);
    final f = SpaceFile(id: '0' * 31 + '7', name: 'holiday.mkv', size: 4, mime: FileKind.mimeOf('holiday.mkv'), sha: '', key: Uint8List(32), prefix: Uint8List(8), by: 'maya', byName: 'Maya', at: 1);
    expect(f.kind, FileKind.video);
    // Already brought down, so it opens from where it is.
    File(store.cachedPath(f))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3, 4]);
    expect(playsVideo, isTrue);
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, Builder(builder: (context) => GestureDetector(key: const ValueKey('open'), behavior: HitTestBehavior.opaque, onTap: () => openSpaceFile(context, space, f, store: store), child: const SizedBox.expand())), AppState(), size: const Size(1100, 700));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(VideoScreen), findsOneWidget);
    expect(engine.opened, store.cachedPath(f));
    expect(find.text('holiday.mkv'), findsOneWidget, reason: 'its name at the top');
    await close(tester);
    await store.clear();
  });

  // Matt, 2026-11-23: "i want to see the mixer when viewing sounds recordings but it just loads the media player
  // view". A call's recording in a Files space (where a circle's are saved) or a space's chat opened as any MP4.
  group('a call\'s recording from a Files space', () {
    late Directory dir;
    late FilesStore store;
    const space = VoiceChannel(seed: '9191919191919191919191919191919191919191919191919191919191919191', name: 'Drop box', kind: SpaceKind.files);

    setUp(() {
      dir = Directory.systemTemp.createTempSync('ghost-rec-open');
      store = FilesStore.forTest(base: null, signer: KeysSigner(NetKeys.generate()), data: dir);
      CallRecorder.folderForTest = Directory('${dir.path}/recordings');
      RecordingPlayback.opensHereForTest = true;
    });
    tearDown(() {
      CallRecorder.folderForTest = null;
      RecordingPlayback.opensHereForTest = null;
      dir.deleteSync(recursive: true);
    });

    /// A file of the space named [name], on this device already: an MP4 of sound tracks named [tracks].
    Future<SpaceFile> here(WidgetTester tester, String name, List<String>? tracks, {String id = '7'}) async {
      final f = SpaceFile(id: '0' * 31 + id, name: name, size: 4, mime: FileKind.mimeOf(name), sha: '', key: Uint8List(32), prefix: Uint8List(8), by: 'maya', byName: 'Maya', at: 1);
      expect(f.kind, FileKind.video);
      final file = File(store.cachedPath(f))..parent.createSync(recursive: true);
      file.writeAsBytesSync([..._box('ftyp', [_ascii('isom')]), ..._box('mdat', [Uint8List(64)]), ..._box('moov', [for (final _ in tracks ?? ['', '']) _soundTrak()])]);
      if (tracks != null) await tester.runAsync(() => Mp4Names.apply(file.path, tracks));
      return f;
    }

    /// Lets the file be looked into (real reads, which a test's own clock doesn't run: each is let finish, then what
    /// waited on it runs and asks for the next), then the screens come in.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump(const Duration(milliseconds: 50));
    }

    Future<void> opener(WidgetTester tester, SpaceFile f) async {
      final sheet = await loadSheet(tester);
      await pumpScreen(tester, sheet, Builder(builder: (context) => GestureDetector(key: const ValueKey('open'), behavior: HitTestBehavior.opaque, onTap: () => openSpaceFile(context, space, f, store: store), child: const SizedBox.expand())), AppState(), size: const Size(1100, 700));
      await tester.tap(find.byKey(const ValueKey('open')));
      await settle(tester);
    }

    testWidgets('opens in the mixer, not the player; the mixer has the way to the player', (tester) async {
      final f = await here(tester, 'rec19a2b3c.mp4', ['Everyone', 'Maya', 'Theo']);
      await opener(tester, f);
      expect(find.byKey(const ValueKey('recording-playback')), findsOneWidget, reason: 'the mixer\'s drawer');
      expect(find.byType(VideoScreen), findsNothing);
      expect(engine.opened, isNull);
      // No decoder under a test, so the drawer says the voices couldn't be opened; what was made for them is there
      // until it closes.
      final opened = Directory('${dir.path}/recordings/opened/file-${f.id}');
      expect(opened.existsSync(), isTrue);
      // Its button for the player: the drawer goes and the same file plays.
      await tester.tap(find.byKey(const ValueKey('recording-plain')));
      await settle(tester);
      expect(find.byKey(const ValueKey('recording-playback')), findsNothing);
      expect(find.byType(VideoScreen), findsOneWidget);
      expect(engine.opened, store.cachedPath(f));
      expect(opened.existsSync(), isFalse, reason: 'a file in no list here leaves nothing decoded behind');
      await close(tester);
      await store.clear();
    });

    testWidgets('whatever it is named, where it is on this device already', (tester) async {
      final f = await here(tester, 'Recording Lounge 2026-11-23T14.05.mp4', ['Everyone', 'Maya']);
      await opener(tester, f);
      expect(find.byKey(const ValueKey('recording-playback')), findsOneWidget);
      expect(find.byType(VideoScreen), findsNothing);
      await close(tester);
      await store.clear();
    });

    testWidgets('any other .mp4 plays in the player as before, and so does a recording where the mixer opens no file', (tester) async {
      final clip = await here(tester, 'holiday.mp4', null);
      await opener(tester, clip);
      expect(find.byType(VideoScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('recording-playback')), findsNothing);
      expect(engine.opened, store.cachedPath(clip));
      await close(tester);
      // A browser or Linux: no decoder for the tracks.
      RecordingPlayback.opensHereForTest = false;
      engine = FakeVideoEngine();
      final rec = await here(tester, 'rec19a2b3c.mp4', ['Everyone', 'Maya'], id: '8');
      await opener(tester, rec);
      expect(find.byType(VideoScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('recording-playback')), findsNothing);
      expect(engine.opened, store.cachedPath(rec));
      await close(tester);
      await store.clear();
    });

    // One not here yet and named as recordings are is brought down in its preview first (the mixer needs the whole
    // file); once here the mixer opens over that page, which keeps both ways in.
    testWidgets('its preview opens the mixer once the file is here, and has Open in the mixer beside Play', (tester) async {
      final f = await here(tester, 'rec19a2b3c.mp4', ['Everyone', 'Maya', 'Theo']);
      final sheet = await loadSheet(tester);
      await pumpScreen(tester, sheet, FilePreviewScreen(channel: space, file: f, store: store, mixer: true), AppState(), size: const Size(1100, 700));
      await settle(tester);
      expect(find.byKey(const ValueKey('recording-playback')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('recording-collapse')));
      await settle(tester);
      expect(find.byKey(const ValueKey('recording-playback')), findsNothing);
      expect(find.text('Open in the mixer'), findsOneWidget);
      expect(find.text('Play'), findsOneWidget);
      await tester.tap(find.text('Open in the mixer'));
      await settle(tester);
      expect(find.byKey(const ValueKey('recording-playback')), findsOneWidget);
      await close(tester);
      await store.clear();
    });
  });

  test('a computer keeps a chat\'s video as a file of its own kind, for the player, in a folder it sweeps', () async {
    final dir = Directory.systemTemp.createTempSync('ghost-video-copy');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = (await LinkCalls.videoCopy(12, Uint8List.fromList([1, 2, 3]), 'MKV', under: dir))!;
    expect(path, endsWith('.mkv'));
    expect(path, contains('${dir.path}/ghost-messaging-video/$pid/12-'));
    expect(File(path).readAsBytesSync(), [1, 2, 3]);
    final odd = (await LinkCalls.videoCopy(13, Uint8List.fromList([1]), '../x', under: dir))!;
    expect(odd, endsWith('.mp4'), reason: 'an ending that is not one is not used');
  });
}
