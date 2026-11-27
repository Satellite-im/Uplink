// A Files space's screens in a browser's page (GMFB-30; docs/OPEN_NETWORK.md part 6): only where the build has them
// (Sms.browserFiles), and there nothing is ever opened in a tab of the app's own address; what came down is read back
// from where the tab holds it.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/files/file_platform.dart';
import 'package:ghost_messaging/files/file_sink.dart' show heldType;
import 'package:ghost_messaging/files/files_store.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/ui/circles/circle_face.dart' show spaceKindsOffered;
import 'package:ghost_messaging/ui/circles/circle_screen.dart' show FilesNotHere, circleSpacePage;
import 'package:ghost_messaging/ui/files_space/file_preview.dart';
import 'package:ghost_messaging/ui/files_space/files_screen.dart';
import 'package:ghost_messaging/ui/video_engine.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/list_harness.dart';

void main() {
  const space = VoiceChannel(seed: '9191919191919191919191919191919191919191919191919191919191919191', name: 'Drop box', kind: SpaceKind.files);
  tearDown(() {
    Sms.browser = false;
    Sms.browserFiles = false;
  });

  test('a browser offers and opens Files spaces only where its build has them; a phone or a computer always', () {
    expect(Sms.filesHere, isTrue);
    expect(spaceKindsOffered, contains(SpaceKind.files));
    Sms.browser = true;
    expect(Sms.filesHere, isFalse);
    expect(spaceKindsOffered, isNot(contains(SpaceKind.files)));
    expect(circleSpacePage(space), isA<FilesNotHere>());
    Sms.browserFiles = true;
    expect(Sms.filesHere, isTrue);
    expect(spaceKindsOffered, contains(SpaceKind.files));
    expect(circleSpacePage(space), isA<FilesSpaceScreen>());
  });

  test('nothing is opened elsewhere from a page, and a held file\'s address plays in the page\'s own player', () {
    // A page's build: no Open (a file opened in a tab of the app's address could read what it keeps).
    expect(FilePlatform.canOpen, isTrue, reason: 'a phone or a computer opens files in their apps');
    expect(VideoEngine.isAddress('blob:https://app.gogho.st/6c1d'), isTrue);
    expect(VideoEngine.isAddress('/tmp/a.mp4'), isFalse);
  });

  test('a held file is said to be itself only where it is a sound or a video: anything else is plain bytes', () {
    expect(heldType('video/mp4'), 'video/mp4');
    expect(heldType('audio/mpeg'), 'audio/mpeg');
    for (final m in ['text/html', 'image/svg+xml', 'application/xhtml+xml', 'image/png', '', 'video/mp4; codecs=x']) {
      expect(heldType(m), 'application/octet-stream', reason: m);
    }
  });

  testWidgets('a browser\'s preview shows words read back from where the tab holds them, never from a path', (tester) async {
    final dir = Directory.systemTemp.createTempSync('ghost-files-web-screen');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = FilesStore.forTest(base: null, signer: KeysSigner(NetKeys.generate()), data: dir, browser: true);
    addTearDown(store.clear);
    final words = 'Words from the space, read in a browser.';
    final f = SpaceFile(id: 'a' * 32, name: 'notes.txt', size: words.length, mime: 'text/plain', sha: '', key: Uint8List(32), prefix: Uint8List(8), by: 'maya', byName: 'Maya', at: 1);
    store.put(space, [f]);
    final sink = HeldFiles.sink()..add(Uint8List.fromList(utf8.encode(words)));
    store.putHeld(f, sink.finish('text/plain'));
    final sheet = await loadSheet(tester);
    await tester.runAsync(() async {
      await pumpScreen(tester, sheet, FilePreviewScreen(channel: space, file: f, store: store), AppState());
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await settle(tester);
    expect(find.text(words), findsOneWidget);
    // Nothing of it written to the page's (absent) disk.
    expect(dir.listSync(), isEmpty);
  });

  // The review of web-files, F2: a page holds what comes down in the tab (Safari: in memory), so opening a file there
  // brings it in only where it is to be shown, and reads out of it only what is shown.
  test('in a browser only what is shown is brought into the tab by opening it, and only the start of words is read', () async {
    SpaceFile of(String name, int size) => SpaceFile(id: 'b' * 32, name: name, size: size, mime: FileKind.mimeOf(name), sha: '', key: Uint8List(32), prefix: Uint8List(8), by: 'maya', byName: 'Maya', at: 1);
    expect(browserShowsHere(of('a.png', 8 << 20)), isTrue);
    expect(browserShowsHere(of('a.png', (8 << 20) + 1)), isFalse);
    expect(browserShowsHere(of('a.txt', 16 << 20)), isTrue);
    expect(browserShowsHere(of('a.txt', (16 << 20) + 1)), isFalse);
    expect(browserShowsHere(of('a.mp4', 512 << 20)), isTrue);
    expect(browserShowsHere(of('a.mp4', (512 << 20) + 1)), isFalse);
    expect(browserShowsHere(of('a.pdf', 10)), isFalse, reason: 'shown nowhere in the page: downloaded when asked');
    final sink = HeldFiles.sink()..add(Uint8List(300 * 1024));
    final url = sink.finish('text/plain');
    expect((await HeldFiles.bytes(url, most: 256 * 1024))!.length, 256 * 1024);
    expect((await HeldFiles.bytes(url))!.length, 300 * 1024);
  });

  testWidgets('a browser\'s preview of a big video brings nothing down by itself, and says how to have it', (tester) async {
    final dir = Directory.systemTemp.createTempSync('ghost-files-web-big');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = FilesStore.forTest(base: null, signer: KeysSigner(NetKeys.generate()), data: dir, browser: true);
    addTearDown(store.clear);
    final f = SpaceFile(id: 'c' * 32, name: 'film.mkv', size: 3 << 30, mime: 'video/x-matroska', sha: '', key: Uint8List(32), prefix: Uint8List(8), by: 'maya', byName: 'Maya', at: 1);
    store.put(space, [f]);
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, FilePreviewScreen(channel: space, file: f, store: store), AppState());
    await settle(tester);
    expect(store.downloading(f), isNull);
    expect(store.transfers, isEmpty);
    expect(find.textContaining('Too big to show in a browser'), findsOneWidget);
  });
}
