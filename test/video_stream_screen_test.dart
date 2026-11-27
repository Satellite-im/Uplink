import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/files/file_stream.dart';
import 'package:ghost_messaging/ui/common.dart' show GhostSpinner;
import 'package:ghost_messaging/ui/video_engine.dart';
import 'package:ghost_messaging/ui/video_screen.dart';

import 'support/fake_video.dart';
import 'support/list_harness.dart';

/// A stand-in for a Files-space file served as it comes down: an address at once (or never), half of it here, and
/// the whole file coming only when the test says.
class FakeStream extends ChangeNotifier implements StreamedMedia {
  FakeStream({this.never = false});
  final bool never;
  bool closed = false;
  String? _failure;
  final wholeAsked = <void Function(int, int)>[];
  final wholeDone = Completer<String>();

  @override
  Future<String> open() => never ? Completer<String>().future : Future.value('http://127.0.0.1:5555/token/clip.mkv');
  @override
  List<(double, double)> held() => const [(0.0, 0.5)];
  @override
  Listenable get changes => this;
  @override
  String? get failure => _failure;
  void fail(String why) {
    _failure = why;
    notifyListeners();
  }

  @override
  Future<String> whole(void Function(int done, int size) progress) {
    wholeAsked.add(progress);
    progress(0, 1000);
    return wholeDone.future;
  }

  @override
  void close() => closed = true;
}

/// The player over a streamed file (lib/ui/video_screen.dart; Matt, 2026-11-18: "would it be possible to setup
/// streaming and buffering of the file?"): it plays from the stream's address, waits a while and no longer (MKVs had
/// "load forever in the app"), says why it can't, and gets the whole file with its progress for another app.
void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('com.alexmercerind/media_kit_video'), (call) async => null);
  });
  tearDown(() {
    VideoEngine.make = VideoEngine.defaultEngine;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('com.alexmercerind/media_kit_video'), null);
  });

  Future<void> open(WidgetTester tester, Widget screen) async {
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, screen, AppState(), size: const Size(1100, 700));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('plays from the stream\'s address; a small spinner only while it waits for more; the stream let go after', (tester) async {
    final engine = FakeVideoEngine();
    VideoEngine.make = () => engine;
    final stream = FakeStream();
    await open(tester, VideoScreen.stream(stream: stream, title: 'clip.mkv', desk: true));
    expect(engine.opened, 'http://127.0.0.1:5555/token/clip.mkv');
    expect(engine.calls, contains('play'));
    expect(find.byType(GhostSpinner), findsNothing, reason: 'playing, not waiting');
    engine.value = engine.value.copyWith(buffering: true, buffered: const Duration(seconds: 60));
    await tester.pump();
    expect(find.byType(GhostSpinner), findsOneWidget, reason: 'stalled: the spinner');
    engine.value = engine.value.copyWith(buffering: false);
    await tester.pump();
    expect(find.byType(GhostSpinner), findsNothing);
    await close(tester);
    expect(engine.calls.last, 'release');
    expect(stream.closed, isTrue);
  });

  testWidgets('a player that is never ready gives up after the wait: the card, and the whole file with its progress for another app', (tester) async {
    final engine = FakeVideoEngine(hangs: true);
    VideoEngine.make = () => engine;
    final stream = FakeStream();
    await open(tester, VideoScreen.stream(stream: stream, title: 'clip.mkv', desk: true));
    expect(find.byType(GhostSpinner), findsOneWidget, reason: 'waiting, for now');
    await tester.pump(const Duration(seconds: 15));
    expect(find.text('This video can\'t be played here.'), findsNothing);
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('This video can\'t be played here.'), findsOneWidget, reason: 'twenty seconds and no longer');
    expect(find.byType(GhostSpinner), findsNothing);
    await tester.tap(find.bySemanticsLabel('Open with another app'));
    // The picture's double tap is waited out first (300 ms) before the button's single one is taken.
    await tester.pump(const Duration(milliseconds: 400));
    expect(stream.wholeAsked, hasLength(1));
    expect(find.textContaining('Getting the whole file… 0%'), findsOneWidget);
    stream.wholeAsked.single(600, 1000);
    await tester.pump();
    expect(find.textContaining('Getting the whole file… 60%'), findsOneWidget);
    // Left before it came (the whole file is never finished here, so nothing is handed to the Mac's own apps).
    await close(tester);
    expect(stream.closed, isTrue);
  });

  testWidgets('a stream that never gives an address gives up too; one that stops coming says why', (tester) async {
    VideoEngine.make = FakeVideoEngine.new;
    await open(tester, VideoScreen.stream(stream: FakeStream(never: true), title: 'clip.mkv', desk: true));
    await tester.pump(const Duration(seconds: 21));
    expect(find.text('This video can\'t be played here.'), findsOneWidget);
    await close(tester);

    final engine = FakeVideoEngine(hangs: true);
    VideoEngine.make = () => engine;
    final stream = FakeStream();
    await open(tester, VideoScreen.stream(stream: stream, title: 'clip.mkv', desk: true));
    stream.fail('The file didn\'t open: it was changed on the way, or isn\'t whole.');
    await tester.pump();
    expect(find.text('This video couldn\'t be loaded.'), findsOneWidget);
    expect(find.text('The file didn\'t open: it was changed on the way, or isn\'t whole.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 21));
    await close(tester);
  });
}
