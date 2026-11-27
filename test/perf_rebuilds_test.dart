import 'dart:convert';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/desktop/store.dart';
import 'package:ghost_messaging/main.dart' show ghostTypography;
import 'package:ghost_messaging/net/hub_carrier.dart' show RoomEvent;
import 'package:ghost_messaging/ui/voice_screen.dart' show CallBanner;
import 'package:ghost_messaging/voice/channels.dart' show Voice;
import 'package:ghost_messaging/voice/voice.dart';
import 'package:glacier/glacier.dart';

import 'support/list_harness.dart';

/// docs/performance-audit.md, findings 1 and 5 (Matt, 2026-11-20: "it's quite laggy on linux"; "Yes, fix both"):
/// a choice written must not rebuild the whole app, and the call banner must not keep the window drawing when there
/// is no call.
void main() {
  group('a choice written', () {
    late ListPhone phone;
    setUp(() => phone = ListPhone(const [])..install());

    test('set to what it already is tells nobody and writes nothing', () {
      final state = AppState();
      var told = 0;
      state.addListener(() => told++);
      state.set('theme', 'dark');
      expect(told, 1);
      state.set('theme', 'dark');
      expect(told, 1);
      expect(phone.prefs, {'theme': 'dark'});
    });

    test('a store\'s bookkeeping is kept without telling the screens', () async {
      final state = AppState();
      var told = 0;
      state.addListener(() => told++);
      state.keep('voice_seen', '{"room":1}');
      await Future<void>.delayed(Duration.zero);
      expect(told, 0);
      expect(state.choice('voice_seen', ''), '{"room":1}');
      expect(phone.prefs['voice_seen'], '{"room":1}');
    });

    testWidgets('leaves the theme as it is: nothing themed is built again for an unrelated choice', (tester) async {
      final sheet = await loadSheet(tester);
      final state = AppState();
      _ReadsTheme.builds = 0;
      _ReadsTheme.themes.clear();
      await tester.pumpWidget(AppScope(
        state: state,
        // As the app's root is (lib/main.dart, lib/desktop/main.dart): the theme made inside a builder that listens
        // to the choices, round screens that are the same widgets from one build to the next.
        child: ListenableBuilder(
          listenable: state,
          builder: (context, _) => Directionality(
            textDirection: TextDirection.ltr,
            child: GlacierTheme(
              sheet: sheet,
              attrs: const {'platform': 'desktop', 'theme': 'dark'},
              typography: ghostTypography(state.emoji),
              child: const _ReadsTheme(),
            ),
          ),
        ),
      ));
      final themes = _ReadsTheme.themes;
      expect(_ReadsTheme.builds, 1);
      state.set('enter_sends', 'off');
      await tester.pump();
      expect(themes, hasLength(1), reason: 'the same tokens: a new typography object each build made new ones');
      expect(_ReadsTheme.builds, 1, reason: 'a screen that only reads the theme is not built again');
      // The emoji set is part of the theme: that one does change it.
      state.setEmoji(state.emoji == 'noto' ? 'twemoji' : 'noto');
      await tester.pump();
      expect(themes, hasLength(2));
    });
  });

  // docs/performance-audit.md, finding 8: a window dragged larger or smaller made new tokens at every frame.
  group('a window being resized', () {
    Future<Tokens> at(WidgetTester tester, TokenSheet sheet, Size size, {Duration? settle}) async {
      late Tokens seen;
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: MediaQueryData(size: size),
          child: GlacierTheme(
            sheet: sheet,
            attrs: const {'platform': 'desktop', 'theme': 'dark'},
            resizeSettle: settle,
            child: Builder(builder: (context) {
              seen = context.tokens;
              return const SizedBox();
            }),
          ),
        ),
      ));
      return seen;
    }

    testWidgets('keeps its theme while the size moves, and takes the new size once it has stood still', (tester) async {
      final sheet = await loadSheet(tester);
      const settle = Duration(milliseconds: 120);
      final first = await at(tester, sheet, const Size(1000, 700), settle: settle);
      expect(first.css.vw, 1000);
      // Dragged: several sizes, a few frames apart.
      for (final w in [1010.0, 1040.0, 1100.0]) {
        expect(identical(await at(tester, sheet, Size(w, 700), settle: settle), first), isTrue, reason: 'still the tokens it had');
        await tester.pump(const Duration(milliseconds: 40));
      }
      await tester.pump(const Duration(milliseconds: 130));
      final after = await at(tester, sheet, const Size(1100, 700), settle: settle);
      expect(identical(after, first), isFalse);
      expect(after.css.vw, 1100, reason: 'the size it came to rest at');
      // Anything else that changes is taken at once.
      late Tokens dark;
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(1100, 700)),
          child: GlacierTheme(sheet: sheet, attrs: const {'platform': 'desktop', 'theme': 'light'}, resizeSettle: settle, child: Builder(builder: (context) {
            dark = context.tokens;
            return const SizedBox();
          })),
        ),
      ));
      expect(dark.attrs['theme'], 'light');
    });

    testWidgets('with no wait asked for, every size is taken at once, as the kit does by itself', (tester) async {
      final sheet = await loadSheet(tester);
      final first = await at(tester, sheet, const Size(1000, 700));
      final next = await at(tester, sheet, const Size(1010, 700));
      expect(identical(first, next), isFalse);
      expect(next.css.vw, 1010);
    });
  });

  group('the computer\'s choices file', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('ghost-prefs'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('many changes together are one write of the newest, and each is kept', () async {
      final store = DeskStore(dir, keychain: false);
      final prefs = <String, String>{};
      final written = <Future<void>>[];
      for (var i = 0; i < 40; i++) {
        prefs['k$i'] = '$i';
        written.add(store.savePrefs(prefs));
      }
      // Read before the write: the choices waiting, not the file's (there is no file yet).
      expect((await store.prefs())['k39'], '39');
      expect(File('${dir.path}/prefs.json').existsSync(), isFalse);
      await Future.wait(written);
      final onDisk = (jsonDecode(File('${dir.path}/prefs.json').readAsStringSync()) as Map).cast<String, String>();
      expect(onDisk, hasLength(40));
      expect(onDisk['k39'], '39');
      // One write: one temporary file was ever named (they are numbered), and none is left.
      expect(dir.listSync().map((f) => f.uri.pathSegments.last).toList(), ['prefs.json']);
      // And a change after it is written too.
      prefs['later'] = 'yes';
      await store.savePrefs(prefs);
      expect((jsonDecode(File('${dir.path}/prefs.json').readAsStringSync()) as Map)['later'], 'yes');
      expect((await store.prefs())['later'], 'yes');
    });

    test('the folder is the person\'s alone', () async {
      final store = DeskStore(dir, keychain: false);
      await store.savePrefs({'a': 'b'});
      final mode = dir.statSync().mode & 0x1ff;
      expect(mode.toRadixString(8), '700');
    }, skip: Platform.isWindows ? 'no file modes on Windows' : false);
  });

  group('the call banner', () {
    final channel = Circle(
      seed: '8' * 64,
      owner: '',
      manifest: CircleManifest(owner: '', version: 1, name: 'Night Owls', hue: 'indigo', icon: 'sparkles', spaces: [CircleSpace(seed: '8b' * 32, name: 'Lounge')]),
    ).channels.first;

    setUp(() {
      ListPhone(const []).install();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost/voicefx'), (call) async => null);
    });
    tearDown(() {
      Voice.instance.session = null;
      Voice.instance.putLook(channel.room, const []);
    });

    testWidgets('asks for no frames with no call, beats during one, and is still again after it', (tester) async {
      final sheet = await loadSheet(tester);
      await pumpScreen(tester, sheet, CallBanner(onOpen: () {}), AppState());
      int tickers() => SchedulerBinding.instance.transientCallbackCount;
      expect(tickers(), 0, reason: 'no call: nothing animating');
      expect(tester.binding.hasScheduledFrame, isFalse);

      Voice.instance.session = VoiceSession(channel: channel, route: _NoRoute(), media: _NoMedia(), name: 'Me');
      Voice.instance.putLook(channel.room, const ['a']);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Lounge'), findsOneWidget);
      expect(tickers(), greaterThan(0), reason: 'in a call the dot beats');

      Voice.instance.session = null;
      Voice.instance.putLook(channel.room, const []);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Lounge'), findsNothing);
      expect(tickers(), 0, reason: 'the call over: the beat has stopped, where it ran for the app\'s life');
      expect(tester.binding.hasScheduledFrame, isFalse);
      // And no clock left ticking: the test would fail on a pending timer otherwise.
    });
  });
}

/// A screen that draws from the theme alone, and counts its builds.
class _ReadsTheme extends StatelessWidget {
  const _ReadsTheme();
  static int builds = 0;
  static final themes = <Tokens>{};

  @override
  Widget build(BuildContext context) {
    builds++;
    themes.add(context.tokens);
    return const SizedBox();
  }
}

class _NoRoute implements VoiceRoute {
  @override
  String get me => 'me-id';
  @override
  Future<List<String>> join(String room, String token) async => const [];
  @override
  void leave(String room) {}
  @override
  void send(String room, Uint8List bytes) {}
  @override
  void look(String room, String token) {}
  @override
  void unlook(String room) {}
  @override
  Stream<RoomEvent> get events => const Stream.empty();
  @override
  Stream<({String room, String from, Uint8List bytes})> get packets => const Stream.empty();
  @override
  Stream<({String room, List<String> members})> get looks => const Stream.empty();
}

class _NoMedia implements VoiceMedia {
  @override
  final ValueNotifier<Map<String, double>> levels = ValueNotifier(const {});
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  set muted(bool on) {}
  @override
  set deafened(bool on) {}
  @override
  Future<void> setVideo(bool on) async {}
  @override
  VoicePeer peer(String id, {required void Function(Map<String, dynamic> candidate) onCandidate}) => throw UnimplementedError();
  @override
  void setPeerVolume(String id, double volume) {}
  @override
  void setPeerMuted(String id, bool muted) {}
}
