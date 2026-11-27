import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/ui/open_space_view.dart';
import 'package:ghost_messaging/ui/shell.dart';
import 'package:ghost_messaging/ui/space_designs/space_design.dart';
import 'package:ghost_messaging/ui/voice_screen.dart' show CallBanner, CallDock;
import 'package:ghost_messaging/voice/channels.dart' show Voice;
import 'package:ghost_messaging/voice/open_space.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/list_harness.dart';
import 'support/open_space_fakes.dart';

/// An open space's call is its floor wherever a call is drawn (Matt, 2026-11-23, on 0.12.20: "the open space is just
/// showing up as a normal call for me and it took a really long time to load"). The call designs (Telegram's is the
/// default, lib/ui/space_designs) were drawn in its place on a phone and pushed over everything on a computer, and the
/// floor was only made once the relay had answered, so until then even the floor's own pages drew a normal call.
/// The pictures, with --update-goldens, are build/open-space-fix/*.png.
Future<void> _fonts() async {
  final loader = FontLoader('Inter Variable')..addFont(File('assets/fonts/InterVariable-latin.ttf').readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
  await loader.load();
}

final _circle = Circle(
  seed: '9' * 64,
  owner: '',
  manifest: CircleManifest(owner: '', version: 1, name: 'Night Owls', hue: 'indigo', icon: 'sparkles', spaces: [
    CircleSpace(seed: '9b' * 32, name: 'Plaza', kind: SpaceKind.open),
    CircleSpace(seed: '9a' * 32, name: 'General', kind: SpaceKind.text, order: 1),
  ]),
);

VoiceChannel get _plaza => _circle.channels.firstWhere((c) => c.name == 'Plaza');

/// Into [c]'s call as Voice.join begins it: the session made and the floor followed at once, before the relay has
/// answered ([joined]: and then answered).
Future<VoiceSession> _begin(WidgetTester tester, VoiceChannel c, {bool joined = true, bool follow = true}) async {
  final v = Voice.instance;
  final s = v.session = VoiceSession(channel: c, route: FakeRoute(FakeHub(), 'me-id'), media: FakeMedia(), name: 'Matt');
  if (follow) OpenSpaces.instance.follow();
  if (joined) await tester.runAsync(s.join);
  s.members['a'] = const VoiceMember('a', name: 'Maya Chen');
  // Tells Voice's listeners, as join does.
  v.putLook(c.room, const ['a']);
  return s;
}

Future<void> _end(WidgetTester tester) async {
  final s = Voice.instance.session;
  Voice.instance.session = null;
  OpenSpaces.instance.followSession(null);
  Voice.instance.putLook(_plaza.room, const []);
  await tester.pumpWidget(const SizedBox.shrink());
  if (s != null) await tester.runAsync(s.leave);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_fonts);
  setUp(() {
    ListPhone(const []).install();
    for (final name in ['ghost/voicefx', 'ghost/sound']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(MethodChannel(name), (call) async => null);
    }
  });
  tearDown(() async {
    await Circles.instance.clear();
  });

  for (final (name, size, wide) in [('a phone', const Size(412, 892), false), ('a wide window', const Size(1100, 832), true)]) {
    {
      testWidgets('on $name, an open space\'s call is its floor on every way in', (tester) async {
        Circles.instance.join(_circle);
        final sheet = await loadSheet(tester);
        final app = AppState();
        await pumpScreen(tester, sheet, const AppShell(), app, size: size, platform: wide ? 'desktop' : 'mobile');
        final shell = AppShellState.live!;
        shell.openCircle(_circle);
        await settle(tester);
        if (!wide) {
          await tester.tap(find.text('Plaza').last);
          await settle(tester);
        }
        expect(find.byType(HangoutScreen), findsOneWidget);

        // The circle's space, joined.
        await _begin(tester, _plaza);
        await settle(tester);
        expect(openSpaceCall(tester.element(find.byType(HangoutScreen))), isFalse, reason: 'no call page is pushed over it');
        await settle(tester);
        expect(find.byType(SpaceCallPage), findsNothing, reason: 'a call\'s page is not drawn for it');
        expect(find.byType(OpenSpaceView), findsOneWidget, reason: 'the space\'s own page is its floor');
        expect(find.byType(CallDock), wide ? findsOneWidget : findsWidgets, reason: 'with the call\'s buttons, once');

        // The call's own page (the Voice page, as Join on a computer and the call's banner open it).
        shell.go('voice');
        await settle(tester);
        expect(find.byType(SpaceCallPage), findsNothing);
        expect(find.byType(OpenSpaceView), findsOneWidget, reason: 'the call\'s page is its floor');
        // The list beside it stays the circle's own: no people list in its place, and the call's buttons once, on the
        // floor (Matt, 2026-11-23: "the call controls are still duplicated in open spaces don't take over the sidebar").
        if (wide) {
          expect(find.byKey(const ValueKey('call-dock-in-pill')), findsNothing);
          expect(find.byType(CallDock), findsOneWidget, reason: 'one set of the call\'s buttons');
        }

        // Put away, and opened again from the call's banner over the circle.
        if (!wide) {
          shell.openCircle(_circle);
          await settle(tester);
          if (find.byType(CallBanner).evaluate().isNotEmpty) {
            await tester.tap(find.byType(CallBanner));
            await settle(tester);
            expect(find.byType(SpaceCallPage), findsNothing);
            expect(find.byType(OpenSpaceView), findsOneWidget, reason: 'the banner opens the floor');
          }
        }
        expect(tester.takeException(), isNull);
        await _end(tester);
      });
    }
  }

  testWidgets('the floor is on the screen the moment a call is begun, saying it is connecting, before the relay answers', (tester) async {
    Circles.instance.join(_circle);
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const AppShell(), AppState());
    AppShellState.live!.openCircle(_circle);
    await settle(tester);
    await tester.tap(find.text('Plaza').last);
    await settle(tester);

    // The relay has not answered (it took 20 to 30 seconds between 0.12.18, 0.12.19 and 0.12.20): the call was a
    // normal call, Telegram's, until it did.
    final s = await _begin(tester, _plaza, joined: false);
    await tester.pump();
    expect(find.byType(SpaceCallPage), findsNothing);
    expect(find.byType(OpenSpaceView), findsOneWidget, reason: 'one frame after the call is begun');
    expect(find.text('Connecting…'), findsOneWidget);

    await tester.runAsync(s.join);
    await settle(tester);
    expect(find.text('Connecting…'), findsNothing);
    expect(find.byType(OpenSpaceView), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _end(tester);
  });

  testWidgets('should a frame come before the floor, it says the space is coming, never a normal call', (tester) async {
    Circles.instance.join(_circle);
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const AppShell(), AppState());
    AppShellState.live!.openCircle(_circle);
    await settle(tester);
    await tester.tap(find.text('Plaza').last);
    await settle(tester);
    await _begin(tester, _plaza, joined: false, follow: false);
    await tester.pump();
    expect(find.byType(SpaceCallPage), findsNothing);
    expect(find.text('Coming into Plaza…'), findsOneWidget);
    OpenSpaces.instance.follow();
    await tester.pump();
    expect(find.byType(OpenSpaceView), findsOneWidget);
    await _end(tester);
  });

  if (autoUpdateGoldenFiles) {
    for (final (name, size, wide) in [('phone', const Size(412, 892), false), ('desktop', const Size(1280, 800), true)]) {
      testWidgets('picture: an open space\'s call on a $name, dark', (tester) async {
        Circles.instance.join(_circle);
        final sheet = await loadSheet(tester);
        final app = AppState()..set('theme', 'dark');
        await pumpScreen(tester, sheet, const AppShell(), app, size: size, platform: wide ? 'desktop' : 'mobile');
        final shell = AppShellState.live!;
        shell.openCircle(_circle);
        await settle(tester);
        if (!wide) {
          await tester.tap(find.text('Plaza').last);
          await settle(tester);
        }
        await _begin(tester, _plaza);
        await settle(tester);
        if (wide) {
          shell.go('voice');
          await settle(tester);
        }
        await expectLater(find.byType(WidgetsApp), matchesGoldenFile('../build/open-space-fix/open-space-$name-dark.png'));
        await _end(tester);
      });
    }
  }

  test('an open space\'s kind survives every way it travels: its link, as kept, a circle\'s list, and the phone\'s', () {
    final c = VoiceChannel.make('Plaza', owner: '02${'a' * 64}', kind: SpaceKind.open);
    expect(c.link, endsWith('.open'));
    // The link was refused as no link at all (its pattern knew voice, text and files only).
    expect(VoiceChannel.fromLink(c.link)?.kind, SpaceKind.open);
    expect(VoiceChannel.fromLink(VoiceChannel.make('Plaza', kind: SpaceKind.open).link)?.kind, SpaceKind.open);
    expect(VoiceChannel.fromJson(c.toJson())?.kind, SpaceKind.open);
    final space = CircleSpace.make('Plaza', kind: SpaceKind.open, order: 0);
    expect(CircleSpace.fromJson(space.toJson())?.kind, SpaceKind.open);
    expect(_circle.channelOf(_circle.manifest.spaces.first).kind, SpaceKind.open);
    // What a computer paired with the phone sends it of a space it made (Voice._deskAdd) carries `k`, as the phone
    // reads it back (VoiceChannel.fromJson).
    final desk = File('lib/voice/channels.dart').readAsStringSync();
    expect(desk, contains("if (c.kind != SpaceKind.voice) 'k': c.kind.wire};"));
    // The browser's join page reads it too (site/join/voice.js), and offers its call.
    expect(File('site/join/voice.js').readAsStringSync(), contains('(voice|text|files|open)'));
    expect(File('site/join/index.html').readAsStringSync(), contains("link.kind !== 'voice' && link.kind !== 'open'"));
  });

  test('Voice.join follows the floor as soon as the call is made, before anything it waits on', () {
    final src = File('lib/voice/channels.dart').readAsStringSync();
    // The work of coming in is Voice._join; Voice.join round it says at once that a call is being come into
    // (Voice.joining, for the screens' "Connecting…").
    final join = src.substring(src.indexOf('Future<void> _join(VoiceChannel c'));
    final body = join.substring(0, join.indexOf('\n  }\n'));
    final follow = body.indexOf('OpenSpaces.instance.follow();');
    expect(follow, greaterThan(body.indexOf('final s = session = VoiceSession(')), reason: 'after the call is made');
    for (final wait in ['await hold(c)', 'await Sms.instance.callStarted', 'await s.join(']) {
      expect(follow, lessThan(body.indexOf(wait)), reason: 'before $wait');
    }
    // And every screen is told then too, so the call is drawn (saying what it waits for) before the chat's room has
    // been opened, which waits for the relay server.
    final told = body.indexOf('notifyListeners();', follow);
    expect(told, greaterThan(follow));
    expect(told, lessThan(body.indexOf('await hold(c)')), reason: 'the call is on the screen before anything is waited for');
  });
}
