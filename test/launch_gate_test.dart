import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/art/loading_logo.dart';
import 'package:ghost_messaging/ui/launch_gate.dart';

import 'support/drawn_ink.dart';

/// A phone's loading splash (lib/ui/launch_gate.dart; Matt, 2026-11-27: "also on the phone add a loading splash
/// screen using the same logo"): the logo turning from the app's first frame, the app put under it once what it
/// starts with has been read (lib/main.dart), and the splash faded away over it when the logo has been seen for its
/// least. Pictures in build/themes/launch-splash (phone-light, phone-dark).
void main() {
  void phone(WidgetTester tester, {Size size = const Size(412, 892), bool dark = false}) {
    tester.view.physicalSize = size * 2.0;
    tester.view.devicePixelRatio = 2.0;
    tester.platformDispatcher.platformBrightnessTestValue = dark ? Brightness.dark : Brightness.light;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  }

  setUp(() => _App.made = _App.pressed = 0);

  final splash = find.byType(PhoneSplash);
  final app = find.byType(_App);
  double solid(WidgetTester tester) => tester.widget<FadeTransition>(find.ancestor(of: splash, matching: find.byType(FadeTransition)).first).opacity.value;
  bool whole(WidgetTester tester) => !tester.widget<IgnorePointer>(find.byKey(const ValueKey('launch-splash'))).ignoring;

  /// The gate up, and the logo's first frame on the page: what the splash's time runs from.
  Future<LaunchHandle> up(WidgetTester tester, {Duration least = LaunchGate.least}) async {
    final (gate, launch) = LaunchGate.forTest(least: least);
    await tester.pumpWidget(gate);
    await filmShown(tester, find.byType(RawImage));
    await tester.pump();
    expect(launch.seenAt, isNotNull);
    return launch;
  }

  for (final dark in [false, true]) {
    testWidgets('the logo turning in the middle of the page, by the phone\'s own setting (${dark ? 'dark' : 'light'})', (tester) async {
      phone(tester, dark: dark);
      final (gate, _) = LaunchGate.forTest();
      await tester.pumpWidget(gate);
      expect(splash, findsOneWidget);
      // Black on white or white on black: what Android's own launch window is (LaunchTheme), so the two meet.
      final c = PhoneSplash.colours(dark);
      expect(c.page, dark ? const Color(0xFF000000) : const Color(0xFFFFFFFF));
      expect(c.ink, dark ? const Color(0xFFFFFFFF) : const Color(0xFF000000));
      expect(tester.widget<ColoredBox>(find.descendant(of: splash, matching: find.byType(ColoredBox))).color, c.page);
      final logo = tester.widget<LoadingLogo>(find.byKey(const ValueKey('launch-logo')));
      expect(logo.color, c.ink);
      expect(logo.width, closeTo(412 * 0.62, 0.01), reason: 'most of the way across a phone');
      final box = tester.getRect(find.byType(LoadingLogo));
      expect(box.center.dx, closeTo(206, 0.01));
      expect(box.center.dy, closeTo(446, 0.01));
      // The clock and the bars' marks read on the page: dark on the light one, light on the dark.
      final bars = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(find.byType(AnnotatedRegion<SystemUiOverlayStyle>)).value;
      expect(bars.statusBarIconBrightness, dark ? Brightness.light : Brightness.dark);
      expect(bars.systemNavigationBarIconBrightness, dark ? Brightness.light : Brightness.dark);
      expect(bars.statusBarColor, const Color(0x00000000));
      expect(bars.systemNavigationBarColor, const Color(0x00000000));
      await filmShown(tester, find.byType(RawImage));
      final drawn = await Drawn.of(tester, tester.element(find.byType(LaunchGate)));
      drawn.keep('build/themes/launch-splash/phone-${dark ? 'dark' : 'light'}.png');
      final shares = drawn.shares(box, ink: c.ink, page: c.page);
      expect(shares.ink, inInclusiveRange(0.15, 0.4), reason: '$shares');
      expect(shares.page, inInclusiveRange(0.5, 0.85), reason: '$shares');
      expect(shares.other, 0, reason: '$shares');
      // The page and nothing else everywhere round the logo.
      expect(drawn.not(Rect.fromLTWH(0, 0, 412, box.top), c.page), 0);
      expect(drawn.not(Rect.fromLTWH(0, box.bottom, 412, 892 - box.bottom), c.page), 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('no smaller than reads as a logo on a narrow screen, no wider than one on an unfolded phone', (tester) async {
    phone(tester, size: const Size(240, 500));
    final (narrow, _) = LaunchGate.forTest();
    await tester.pumpWidget(narrow);
    expect(tester.widget<LoadingLogo>(find.byType(LoadingLogo)).width, 160);
    tester.view.physicalSize = const Size(900, 1000) * 2.0;
    await tester.pump();
    expect(tester.widget<LoadingLogo>(find.byType(LoadingLogo)).width, 340);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the app goes under it at once, and it comes off once the logo has been seen for its least', (tester) async {
    phone(tester);
    final launch = await up(tester);
    // Read in a moment: the app is under the splash from the next frame, the whole screen, and can't be pressed.
    launch.open(const _App());
    await tester.pump();
    expect(app, findsOneWidget);
    expect(splash, findsOneWidget);
    expect(tester.getSize(app), const Size(412, 892), reason: 'the whole screen, as it was when it stood there alone');
    expect(solid(tester), 1);
    expect(whole(tester), isTrue);
    expect(tester.widget<BlockSemantics>(find.byType(BlockSemantics)).blocking, isTrue, reason: 'nothing under it is read out');
    await tester.tapAt(const Offset(206, 446));
    expect(_App.pressed, 0, reason: 'a press on the splash is not a press on what is under it');
    expect(launch.took, isNotNull);
    // Still the logo most of a second on, though the app has been ready all along.
    await tester.pump(const Duration(milliseconds: 700));
    expect(launch.leaving, isFalse);
    expect(solid(tester), 1);
    // Past its least: it fades away over the app, which can be pressed from the moment it starts to go.
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(launch.leaving, isTrue);
    expect(whole(tester), isFalse);
    expect(tester.widget<BlockSemantics>(find.byType(BlockSemantics)).blocking, isFalse);
    await tester.pump(LaunchGate.fade ~/ 2);
    expect(solid(tester), inInclusiveRange(0.3, 0.7), reason: 'half way gone');
    await tester.tapAt(const Offset(206, 446));
    expect(_App.pressed, 1);
    await tester.pump(LaunchGate.fade);
    await tester.pump();
    expect(launch.gone, isTrue);
    expect(splash, findsNothing);
    expect(find.byType(LoadingLogo), findsNothing);
    expect(launch.leftAt, isNotNull);
    // The app was made once and never again: the splash coming off it changed nothing of it.
    expect(_App.made, 1);
    expect(tester.getSize(app), const Size(412, 892));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a start that took longer than the logo\'s least goes as soon as the app has settled under it', (tester) async {
    phone(tester);
    final launch = await up(tester);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(launch.leaving, isFalse, reason: 'nothing to leave for until the app is there');
    launch.open(const _App());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(launch.leaving, isFalse, reason: 'the app\'s first frames are drawn under it, not through a fade');
    await tester.pump(const Duration(milliseconds: 120));
    expect(launch.leaving, isTrue);
    await tester.pump(LaunchGate.fade);
    await tester.pump(LaunchGate.fade);
    expect(splash, findsNothing);
  });

  testWidgets('the logo\'s least runs from when it is seen, however long the app has been ready', (tester) async {
    phone(tester);
    // Android starts the app's Dart while it is still making the screen: the app can be ready, and the logo in a
    // frame, before any frame has reached the screen.
    final (gate, launch) = LaunchGate.forTest(drawn: false);
    await tester.pumpWidget(gate);
    launch.open(const _App());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(launch.leaving, isFalse, reason: 'settled long since, but the logo has not been seen');
    await filmShown(tester, find.byType(RawImage));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    expect(launch.seenAt, isNull, reason: 'in a frame, but no frame is on the screen yet');
    expect(launch.leaving, isFalse);
    launch.screenDrawn();
    expect(launch.seenAt, isNotNull);
    await tester.pump(const Duration(milliseconds: 700));
    expect(launch.leaving, isFalse, reason: 'seen for 0.7 s of its 0.9');
    await tester.pump(const Duration(milliseconds: 250));
    expect(launch.leaving, isTrue);
    await tester.pump(LaunchGate.fade);
    await tester.pump(LaunchGate.fade);
    expect(splash, findsNothing);
    expect(_App.made, 1);
  });

  testWidgets('opened to show something, the app is not kept waiting for the logo', (tester) async {
    phone(tester);
    final launch = await up(tester);
    launch.open(const _App());
    await tester.pump();
    launch.hurry();
    await tester.pump(const Duration(milliseconds: 100));
    expect(launch.leaving, isFalse);
    await tester.pump(const Duration(milliseconds: 120));
    expect(launch.leaving, isTrue, reason: 'a fifth of a second after the app was there, not most of a second');
    await tester.pump(LaunchGate.fade);
    await tester.pump(LaunchGate.fade);
    expect(splash, findsNothing);
    // Said before the app was there: the same.
    final (gate, early) = LaunchGate.forTest();
    await tester.pumpWidget(KeyedSubtree(key: const ValueKey('again'), child: gate));
    early.hurry();
    early.open(const _App());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(early.leaving, isTrue);
    await tester.pump(LaunchGate.fade);
    await tester.pump(LaunchGate.fade);
    expect(splash, findsNothing);
    // And with no splash up there is nothing to hurry.
    LaunchGate.hurry();
  });

  testWidgets('a logo that was never seen doesn\'t leave the splash up for good', (tester) async {
    phone(tester);
    final (gate, launch) = LaunchGate.forTest();
    await tester.pumpWidget(gate);
    launch.open(const _App());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2800));
    expect(launch.seenAt, isNull);
    expect(launch.leaving, isFalse);
    await tester.pump(const Duration(milliseconds: 300));
    expect(launch.leaving, isTrue, reason: 'three seconds after the app was under it, whatever else');
    await tester.pump(LaunchGate.fade);
    await tester.pump(LaunchGate.fade);
    expect(splash, findsNothing);
  });

  testWidgets('a build that can\'t read the logo has nothing to show, so nothing to wait for', (tester) async {
    phone(tester);
    final (gate, launch) = LaunchGate.forTest();
    await tester.pumpWidget(DefaultAssetBundle(bundle: _Nothing(), child: gate));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    launch.open(const _App());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(launch.leaving, isTrue);
    await tester.pump(LaunchGate.fade);
    await tester.pump(LaunchGate.fade);
    expect(splash, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a phone asked to move less shows the logo still', (tester) async {
    phone(tester);
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final (gate, _) = LaunchGate.forTest();
    await tester.pumpWidget(gate);
    expect((tester.widget<Image>(find.byType(Image)).image as AssetImage).assetName, LoadingLogo.still);
  });

  // lib/main.dart, read as it is written: the splash goes up before anything is read, and every way out of the
  // start from there draws something. A way out that drew nothing would leave the logo turning for good.
  test('the phone\'s start puts the splash up first and something over it whichever way it goes', () {
    final source = File('lib/main.dart').readAsStringSync();
    final up = source.indexOf('final launch = LaunchGate.show();');
    final open = source.indexOf('launch.open(GhostMessagingApp(');
    expect(up, greaterThan(0));
    expect(open, greaterThan(up));
    for (final read in ['await standaloneSetup()', 'await overlaySetup()', 'state.load()', 'AccentSheets.load()', 'InstalledPlugins.instance.load(', 'AppLock.start(']) {
      expect(source.indexOf(read), inExclusiveRange(up, open), reason: '$read is waited for under the splash');
    }
    final between = source.substring(up, open).split('\n').map((line) => line.replaceFirst(RegExp(r'//.*$'), '')).join('\n');
    final ways = RegExp(r'\breturn\b[^;]*;').allMatches(between).map((m) => m.group(0)!).toList();
    expect(ways, isNotEmpty);
    for (final way in ways) {
      expect(way, startsWith('return runApp('), reason: 'a way out of the start that draws nothing over the splash');
    }
    expect(source.contains('runApp(GhostMessagingApp('), isFalse, reason: 'the app goes in under the splash');
    // A computer's start, and an iPhone paired as one, go off to their own splash before this one is put up.
    expect(source.lastIndexOf('return desktopMain();'), lessThan(up));
    // And what the app is opened to show is not held up by it.
    final opens = source.indexOf('Future<void> _open(OpenRequest req) async {');
    expect(source.indexOf('LaunchGate.hurry();', opens), inExclusiveRange(opens, opens + 400));
  });
}

/// What stands in for the app: it counts how often it was made and pressed.
class _App extends StatefulWidget {
  const _App();
  static int made = 0, pressed = 0;

  @override
  State<_App> createState() => _AppState();
}

class _AppState extends State<_App> {
  @override
  void initState() {
    super.initState();
    _App.made++;
  }

  @override
  Widget build(BuildContext context) => GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => _App.pressed++, child: const SizedBox.expand());
}

/// A build with none of the app's pictures in it.
class _Nothing extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => throw FlutterError('no $key in this build');
}
