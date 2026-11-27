import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/ui/open_space_view.dart';
import 'package:ghost_messaging/voice/open_space.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/list_harness.dart';
import 'support/open_space_fakes.dart';

/// An open space's floor on the screen (lib/ui/open_space_view.dart; Matt, 2026-11-23: "a top down view and lets you
/// move around in the space ... allow walking around with wasd or arrow keys"): everyone is drawn where they stand, the
/// keys and a press walk this device, and groups are made and changed from the floor. The pictures are
/// `test/shots/open-space-*`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    for (final name in ['ghost_messaging/sms', 'ghost/sound']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
  });

  /// Three in an open space's call (this device is a), each with a floor, drawn at [size]. What is said between them
  /// takes a pump to arrive.
  Future<({OpenSpace a, OpenSpace b, OpenSpace c, Map<String, VoiceSession> sessions, Future<void> Function() end})> scene(WidgetTester tester, {Size size = const Size(1000, 720), String platform = 'desktop', bool dark = false}) async {
    final hub = FakeHub();
    final ch = VoiceChannel.make('Plaza', kind: SpaceKind.open);
    final sessions = <String, VoiceSession>{};
    final floors = <String, OpenSpace>{};
    for (final id in ['a', 'b', 'c']) {
      final s = sessions[id] = VoiceSession(channel: ch, route: FakeRoute(hub, id), media: FakeMedia(), name: {'a': 'Matt', 'b': 'Maya', 'c': 'Kevin'}[id]!);
      await tester.runAsync(s.join);
      // The floor's clock is the test's, so a pump of a second is a second's walk.
      floors[id] = OpenSpace(s, store: FakeStore(), random: math.Random(3), now: () => tester.binding.clock.now());
    }
    void put(String id, Offset2 at) {
      floors[id]!.walkTo(at);
      while (floors[id]!.walking) {
        floors[id]!.step(10);
      }
    }

    put('a', const Offset2(1000, 800));
    put('b', const Offset2(1090, 800));
    put('c', const Offset2(1500, 1000));
    final sheet = await loadSheet(tester);
    final app = AppState();
    if (dark) app.set('theme', 'dark');
    await pumpScreen(tester, sheet, OpenSpaceView(session: sessions['a']!, floor: floors['a']!), app, size: size, platform: platform);
    return (
      a: floors['a']!,
      b: floors['b']!,
      c: floors['c']!,
      sessions: sessions,
      end: () async {
        // The page goes first, as it does in the app when a call is left.
        await tester.pumpWidget(const SizedBox.shrink());
        for (final f in floors.values) {
          f.dispose();
        }
        // Leaving waits on real time (the route's own closing), as joining does.
        await tester.runAsync(() async {
          for (final s in sessions.values) {
            await s.leave();
          }
        });
        await tester.pump(const Duration(milliseconds: 50));
      },
    );
  }

  /// Time for what was said to reach the others and for everyone to be drawn where they now stand: the calls were
  /// joined in real time (their listeners run there), so both clocks are let run.
  Future<void> beat(WidgetTester tester) async {
    // Long enough for each floor to say its place once more (OpenSpace.beatEvery): with two clocks, words said a
    // moment apart can arrive out of turn, and the last word is what stands.
    await tester.pump(OpenSpace.beatEvery + const Duration(milliseconds: 200));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 60));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Offset centreOf(WidgetTester tester, String key) => tester.getCenter(find.byKey(ValueKey(key)));

  testWidgets('everyone is drawn where they stand, this device in the middle, and the far one fainter', (tester) async {
    final s = await scene(tester);
    await beat(tester);
    expect(find.byKey(const ValueKey('open-person-me')), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
    expect(find.text('Maya'), findsOneWidget);
    expect(find.text('Kevin'), findsOneWidget);
    final me = centreOf(tester, 'open-person-me'), maya = centreOf(tester, 'open-person-b'), kevin = centreOf(tester, 'open-person-c');
    expect(me.dx, closeTo(500, 1), reason: 'this device in the middle of the view');
    expect(maya.dx, greaterThan(me.dx));
    expect(maya.dy, closeTo(me.dy, 1), reason: 'Maya stands level, just to the right');
    expect(kevin.dx, greaterThan(maya.dx));
    expect(kevin.dy, greaterThan(me.dy), reason: 'Kevin stands further right and down');
    double faint(String id) => tester.widget<Opacity>(find.descendant(of: find.byKey(ValueKey('open-person-$id')), matching: find.byType(Opacity)).first).opacity;
    expect(faint('b'), 1.0, reason: 'near: heard whole');
    expect(faint('c'), lessThan(0.75), reason: 'far: fainter, but still there to walk to');
    await s.end();
  });

  testWidgets('W A S D and the arrow keys walk this device, a key let go stops it, and a press on the floor walks there', (tester) async {
    final s = await scene(tester);
    await beat(tester);
    final start = s.a.me.at;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyD);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(s.a.me.at.x, greaterThan(start.x + 200), reason: 'walked right while D was held');
    expect(s.a.me.at.y, closeTo(start.y, 0.01));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyD);
    final rest = s.a.me.at;
    await tester.pump(const Duration(milliseconds: 500));
    expect(s.a.me.at, rest, reason: 'stopped when the key was let go');
    expect(s.a.walking, isFalse);

    // Up and left together: walking on the slant, no faster than straight.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    expect(s.a.me.at.x, lessThan(rest.x));
    expect(s.a.me.at.y, lessThan(rest.y));
    expect(s.a.me.at.to(rest), lessThan(OpenWorld.speed * 1.2));

    // A press: this device walks to where was pressed and stops there.
    final before = s.a.me.at;
    final scale = OpenSpaceView.scaleFor(const Size(1000, 720));
    await tester.tapAt(const Offset(500 + 150, 360 + 90));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(s.a.walking, isFalse);
    expect(s.a.me.at.x, closeTo(before.x + 150 / scale, 3));
    expect(s.a.me.at.y, closeTo(before.y + 90 / scale, 3));
    await beat(tester);
    // And the others heard where it went.
    expect(s.b.placeOf('a').at.to(s.a.me.at), lessThan(3));
    await s.end();
  });

  testWidgets('a group is made from the floor, drawn with its name and count, and removed from its menu', (tester) async {
    final s = await scene(tester);
    await beat(tester);
    await tester.tap(find.byKey(const ValueKey('open-new-group')));
    await settle(tester);
    expect(find.text('New group here'), findsOneWidget);
    await tester.tap(find.text('Movie night'));
    await settle(tester);
    await beat(tester);
    final g = s.a.groups.single;
    expect(g.name, 'Movie night');
    expect(find.byKey(ValueKey('open-group-${g.id}')), findsOneWidget);
    // This device and Maya stand in it; the others have it too.
    expect(s.a.countIn(g.id), 2);
    expect(find.descendant(of: find.byKey(ValueKey('open-group-${g.id}')), matching: find.text('2')), findsOneWidget);
    expect(s.b.groups.single.name, 'Movie night');

    await tester.tap(find.descendant(of: find.byKey(ValueKey('open-group-${g.id}')), matching: find.text('Movie night')));
    await settle(tester);
    expect(find.text('Move it here'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await settle(tester);
    await beat(tester);
    expect(s.a.groups, isEmpty);
    expect(s.c.groups, isEmpty, reason: 'gone for everyone');
    await s.end();
  });

  for (final dark in [false, true]) {
    testWidgets('how it looks on a computer and on a phone, ${dark ? 'dark' : 'light'}', (tester) async {
      for (final (name, size, platform) in [('open-space', const Size(1000, 720), 'desktop'), ('open-space-phone', const Size(412, 760), 'mobile')]) {
        final s = await scene(tester, size: size, platform: platform, dark: dark);
        await beat(tester);
        s.a.addGroup('Valorant');
        s.c.addGroup('Movie night');
        await beat(tester);
        if (autoUpdateGoldenFiles) await expectLater(find.byType(WidgetsApp), matchesGoldenFile('shots/$name-${dark ? 'dark' : 'light'}.png'));
        await s.end();
      }
    });
  }
  test('the view never shows past the walls: it follows this device until an edge of it reaches one, then stays (Matt, 2026-11-23: "when we get to the wall stop moving the camera so we don\'t see past the wall")', () {
    const size = Size(1000, 720), centre = Offset(500, 360);
    final scale = OpenSpaceView.scaleFor(size);
    // What of the floor is at the view's four edges, for someone standing at [me].
    Rect seen(Offset me) {
      final cam = OpenSpaceView.cameraFor(me, size, centre, scale);
      return Rect.fromLTRB(cam.dx - centre.dx / scale, cam.dy - centre.dy / scale, cam.dx + (size.width - centre.dx) / scale, cam.dy + (size.height - centre.dy) / scale);
    }

    // In the middle of the room the view is centred on this device.
    expect(OpenSpaceView.cameraFor(const Offset(1200, 800), size, centre, scale), const Offset(1200, 800));
    // Anywhere on the floor, corners included, no edge of the view is past the walls' outside.
    const walls = Rect.fromLTRB(-30, -134, OpenWorld.width + 30, OpenWorld.height + 134);
    for (final me in [Offset.zero, const Offset(OpenWorld.width, 0), const Offset(0, OpenWorld.height), const Offset(OpenWorld.width, OpenWorld.height), const Offset(300, 1500), const Offset(2399, 20)]) {
      final r = seen(me);
      expect(r.left, greaterThanOrEqualTo(walls.left - 0.001), reason: '$me');
      expect(r.top, greaterThanOrEqualTo(walls.top - 0.001), reason: '$me');
      expect(r.right, lessThanOrEqualTo(walls.right + 0.001), reason: '$me');
      expect(r.bottom, lessThanOrEqualTo(walls.bottom + 0.001), reason: '$me');
    }
    // A view bigger than the room shows the room in its middle.
    const huge = Size(4000, 3000), mid = Offset(2000, 1500);
    final all = OpenSpaceView.cameraFor(const Offset(10, 10), huge, mid, 1);
    expect(all, const Offset(OpenWorld.width / 2, OpenWorld.height / 2));
  });

  // The walls (Matt, 2026-11-23: "add 3d walls to the edges so it shows a 2.5d wall around the edges"): the far wall's
  // face and the side wall's top at the far corner, and the near wall's top and outer face at the near one.
  for (final dark in [false, true]) {
    testWidgets('the walls round the floor, at its far corner and its near one, ${dark ? 'dark' : 'light'}', (tester) async {
      final s = await scene(tester, dark: dark);
      for (final (name, at) in [('open-space-walls-far', const Offset2(230, 200)), ('open-space-walls-near', Offset2(OpenWorld.width - 230, OpenWorld.height - 200))]) {
        s.a.walkTo(at);
        while (s.a.walking) {
          s.a.step(10);
        }
        await beat(tester);
        expect(s.a.me.at, at);
        // The view stopped at the walls: this device is drawn off its middle, towards the corner it walked to.
        final drawn = centreOf(tester, 'open-person-me');
        at.x < OpenWorld.width / 2 ? expect(drawn.dx, lessThan(450)) : expect(drawn.dx, greaterThan(550));
        at.y < OpenWorld.height / 2 ? expect(drawn.dy, lessThan(330)) : expect(drawn.dy, greaterThan(400));
        if (autoUpdateGoldenFiles) await expectLater(find.byType(WidgetsApp), matchesGoldenFile('shots/$name-${dark ? 'dark' : 'light'}.png'));
      }
      await s.end();
    });
  }
}
