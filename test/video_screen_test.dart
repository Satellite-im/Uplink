import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/ui/common.dart' show GhostSpinner;
import 'package:ghost_messaging/ui/video_engine.dart';
import 'package:ghost_messaging/ui/video_screen.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'support/fake_video.dart';
import 'support/list_harness.dart';

/// The app's own video player (lib/ui/video_screen.dart; Matt, 2026-11-15: "id like a video player built with glacier
/// UI right now it looks like a very old android core system player"): it plays as it opens, the dock plays and
/// pauses and mutes, and a double tap on the right goes on ten seconds.
void main() {
  // These drive video_player's engine (the phone's) through its platform stand-in, whatever the machine running them.
  setUp(() => VideoEngine.make = VideoPlayerEngine.new);
  tearDown(() => VideoEngine.make = VideoEngine.defaultEngine);

  testWidgets('plays as it opens; play, pause, mute and a double tap to skip', (tester) async {
    final fake = FakeVideoPlayer();
    VideoPlayerPlatform.instance = fake;
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const VideoScreen(path: '/tmp/none.mp4', title: 'Maya Chen'), AppState());
    // The player is made once the screen has come in (at most 600 ms on).
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(fake.calls, contains('play'));
    expect(find.text('2:40'), findsOneWidget);
    expect(find.text('Maya Chen'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Mute'));
    await tester.pump();
    expect(fake.calls, contains('volume 0.0'));
    final size = tester.getSize(find.byType(VideoScreen));
    await tester.tapAt(Offset(size.width * 0.8, size.height / 2));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(Offset(size.width * 0.8, size.height / 2));
    await tester.pump(const Duration(milliseconds: 400));
    expect(fake.calls.where((c) => c.startsWith('seek')), isNotEmpty, reason: 'a double tap on the right goes on');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
  });

  // Matt, 2026-11-17: "The app has gotten pretty laggy, especially when opening videos and exiting them".
  testWidgets('opened before its file is here: a spinner, then it plays; closed, the player goes once the screen has', (tester) async {
    final fake = FakeVideoPlayer();
    VideoPlayerPlatform.instance = fake;
    final sheet = await loadSheet(tester);
    final file = Completer<String?>();
    await pumpScreen(tester, sheet, VideoScreen.coming(file: file.future, title: 'Maya Chen'), AppState());
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.byType(GhostSpinner), findsOneWidget, reason: 'the screen is there at once, waiting');
    expect(fake.calls, isNot(contains('play')));
    file.complete('/tmp/none.mp4');
    // Then made once the screen has come in (this page never says it has: the wait's 600 ms cap).
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 100));
    expect(fake.calls, contains('play'));
    // Closed: quiet at once, let go a moment later.
    await tester.pumpWidget(const SizedBox());
    expect(fake.calls, contains('pause'));
    expect(fake.calls.where((c) => c.startsWith('dispose')), isEmpty, reason: 'not while the screen goes');
    // (The release itself, 400 ms on, is video_player's own dispose; this stand-in never finishes it.)
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('a file that never comes says so', (tester) async {
    VideoPlayerPlatform.instance = FakeVideoPlayer();
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, VideoScreen.coming(file: Future.value(null)), AppState());
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('This video couldn\'t be opened.'), findsOneWidget);
  });
}
