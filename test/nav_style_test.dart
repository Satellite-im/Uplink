import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/ui/nav_style.dart';
import 'package:ghost_messaging/ui/shell.dart';
import 'package:ghost_messaging/voice/voice.dart' show SpaceKind;

import 'support/list_harness.dart';

/// One navigation on every page (Matt, 2026-11-19: "work on a unified navigation across the whole app instead of it
/// changing navigations on every page ... including a navigation rail version of the app. It should include the
/// circles icons like discord and slack does ... give me a setting in developer settings to switch between the
/// different views"). Each style is pictured on a phone and a wide window, on the conversations and inside a circle,
/// at build/themes/nav-style/<style>-<size>-<where>.png.
Future<void> _fonts() async {
  final loader = FontLoader('Inter Variable')..addFont(File('assets/fonts/InterVariable-latin.ttf').readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
  await loader.load();
}

Circle _circle(String n, String name, String hue, String icon, {String? picture}) => Circle(
      seed: n * 64,
      owner: '',
      manifest: CircleManifest(owner: '', version: 1, name: name, hue: hue, icon: icon, picture: picture, spaces: [
        CircleSpace(seed: '${n}a' * 32, name: 'General', kind: SpaceKind.text),
        CircleSpace(seed: '${n}b' * 32, name: 'Lounge', order: 1),
      ]),
    );

final _owls = _circle('7', 'Night Owls', 'indigo', 'sparkles');
// With a picture of its own: a square one, a dark ground to its edges, which the rail's round must fill with none of
// the circle's colour round its rim (Matt, 2026-11-19: "the icons inside the sidebar rail for the circles bleed around
// the edges since they're square and not zoomed to fit").
final _alpha = _circle('8', 'Alpha Testers', 'teal', 'flask-conical', picture: base64.encode(File('test/fixtures/circle-face.png').readAsBytesSync()));

Future<void> _keep(WidgetTester tester, String name) async {
  final element = find.byType(WidgetsApp).evaluate().single;
  await tester.runAsync(() async {
    final image = await captureImage(element);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final file = File('build/themes/nav-style/$name.png');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(png!.buffer.asUint8List());
  });
}

Finder _key(String k) => find.byKey(ValueKey(k));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_fonts);
  setUp(() => ListPhone([
        ListPhone.conversation(1, '+15551230001', 'See you at 7', name: 'Maya Chen'),
        ListPhone.conversation(2, '+15551230002', 'The build is out', name: 'Sam Ortiz'),
      ]).install());
  tearDown(() async => Circles.instance.clear());

  for (final (size, at) in [('phone', const Size(412, 892)), ('wide', const Size(1000, 760))]) {
    for (final style in NavStyle.values) {
      testWidgets('${style.name} on a $size: the conversations and a circle', (tester) async {
        Circles.instance.join(_owls);
        Circles.instance.join(_alpha);
        final state = AppState()..set(NavStyle.pref, style.name);
        final sheet = await loadSheet(tester);
        await pumpScreen(tester, sheet, const AppShell(), state, size: at);
        await settle(tester);
        await _keep(tester, '${style.name}-$size-home');
        // Mark all read and Share feedback are rows under the search in every style, not a ring of the rail or a button
        // beside the search (Matt, 2026-11-20: "layout the mark all read and the share feedback buttons to a icon list
        // ... under the searchbar").
        expect(_key('quick-mark-read'), findsOneWidget);
        expect(_key('share-feedback'), findsOneWidget);
        expect(tester.getTopLeft(_key('share-feedback')).dy, greaterThan(tester.getTopLeft(_key('quick-mark-read')).dy));
        // Share feedback opens over the whole app, in the middle of the window, not in the sidebar (Matt, 2026-11-20: "the
        // share feedback drawer should open over the whole app not just in the sidebar").
        await tester.tap(_key('share-feedback'));
        await settle(tester);
        expect(_key('feedback-drawer'), findsOneWidget);
        expect(tester.getCenter(_key('feedback-drawer')).dx, closeTo(at.width / 2, 2));
        await _keep(tester, '${style.name}-$size-feedback');
        await tester.tapAt(const Offset(4, 4));
        await settle(tester);
        expect(_key('feedback-drawer'), findsNothing);

        AppShellState.live!.openCircle(_owls);
        await settle(tester);
        await _keep(tester, '${style.name}-$size-circle');

        switch (style) {
          case NavStyle.classic:
            // The circle's own dock in place of the app's.
            expect(_key('nav-home'), findsOneWidget);
            expect(_key('nav-messages'), findsNothing);
          case NavStyle.dock:
            // The app's rings stay, inside the circle too: the Marketplace's among them (Matt, 2026-11-20: "Move plugins
            // out of settings into a marketplace button on the navigation rail with a marketplace icon").
            expect(_key('nav-home'), findsNothing);
            for (final id in ['new', 'messages', 'contacts', 'archive', 'marketplace', 'settings']) {
              expect(_key('nav-$id'), findsOneWidget, reason: id);
            }
          case NavStyle.rail:
            // No pill: the rail, its circles by their faces, and Home taking the circle away.
            expect(_key('nav-messages'), findsNothing);
            // The Marketplace's ring at the foot, between Archive and Settings.
            final archive = tester.getTopLeft(_key('rail-archive')).dy, market = tester.getTopLeft(_key('rail-marketplace')).dy, settings = tester.getTopLeft(_key('rail-settings')).dy;
            expect(market, greaterThan(archive));
            expect(market, lessThan(settings));
            expect(_key('rail-circle-${_owls.seed}'), findsOneWidget);
            expect(_key('rail-circle-${_alpha.seed}'), findsOneWidget);
            await tester.tap(_key('rail-circle-${_alpha.seed}'));
            await settle(tester);
            expect(AppShellState.live!.openCircleSeed, _alpha.seed);
            // Its picture fills its face, one ring round it, the rail's halo (Matt, 2026-11-20: "make sure the circle
            // icons take up the full width there are double borders right now").
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
            await settle(tester);
            await _keep(tester, '${style.name}-$size-picture-open');
            // The open circle's mark is a halo in its own colour round its face, not a bar at the rail's edge (Matt,
            // 2026-11-20: "the hover and click indicator on the rail is too similar to discords").
            final halo = tester.widget<AnimatedContainer>(_key('rail-halo-${_alpha.seed}'));
            expect(((halo.decoration as BoxDecoration).border as Border).top.color.a, 1, reason: 'whole round the open one');
            final other = tester.widget<AnimatedContainer>(_key('rail-halo-${_owls.seed}'));
            expect(((other.decoration as BoxDecoration).border as Border).top.color.a, 0, reason: 'none round the others');
            await tester.tap(_key('rail-home'));
            await settle(tester);
            expect(AppShellState.live!.circleOpen, isFalse);
        }

        // What is unread in Messages is counted on its ring, the rail's Home or the pill's Messages (GMFB-17, Matt:
        // "When messages have unreads the message bubble icon in the sidebar should show the count in a unread badge").
        AppShellState.live!.messagesUnread.value = 3;
        await tester.pump();
        final ring = _key(style == NavStyle.rail ? 'rail-home' : 'nav-messages');
        if (ring.evaluate().isNotEmpty) expect(find.descendant(of: ring, matching: find.text('3')), findsOneWidget, reason: 'the count on Messages');
        AppShellState.live!.messagesUnread.value = 0;
        await tester.pump();

        // Settings: the same navigation stays where it is unified, on a phone too.
        AppShellState.live!.settings();
        await settle(tester);
        await _keep(tester, '${style.name}-$size-settings');
        if (style == NavStyle.rail) expect(_key('rail-settings'), findsOneWidget);
      });
    }
  }

  // The rail's rings a little smaller on a computer, the pill's size on a phone (Matt, 2026-11-20: "make the navigtion
  // rail icons just a bit smaller as well", then "leave them the same size on mobile, though").
  testWidgets('the rail\'s rings are smaller on a computer than on a phone', (tester) async {
    final sides = <String, double>{};
    for (final platform in ['mobile', 'desktop']) {
      final state = AppState()..set(NavStyle.pref, NavStyle.rail.name);
      final sheet = await loadSheet(tester);
      await pumpScreen(tester, sheet, const AppShell(), state, size: const Size(1000, 760), platform: platform);
      await settle(tester);
      await _keep(tester, 'rail-$platform-rings');
      sides[platform] = tester.getSize(_key('rail-settings')).height;
    }
    expect(sides['desktop']!, lessThan(sides['mobile']! * 0.95));
    expect(sides['desktop']!, greaterThan(sides['mobile']! * 0.75));
  });
}
