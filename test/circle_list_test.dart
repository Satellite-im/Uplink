// A circle's list, the one way a circle is drawn (Matt, 2026-11-17: "Lets remove the other views and focus on the list
// view / layout it's the most practical of them all so far"): it draws a busy made-up circle without overflowing on a
// small phone (360 wide), as a wide window's sidebar and across a whole 1180-wide window, in every look and brightness;
// each space says what is going on in it (who is talking, how many files, the newest message); a press opens a space;
// New space ends the list for whoever may add one; and nothing offers a choice of layout any more.
//
// With THEME_SHOTS=1 each is also kept as a picture at build/themes/circle-list/<look>-<theme>[-wide].png.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/main.dart' show InkOverrides, ghostTypography;
import 'package:ghost_messaging/ui/circles/circle_face.dart';
import 'package:ghost_messaging/ui/circles/circle_list.dart';
import 'package:ghost_messaging/ui/circles/circle_view.dart';
import 'package:ghost_messaging/ui/common.dart' show Avatar;
import 'package:ghost_messaging/ui/ripple_avatar.dart';
import 'package:ghost_messaging/ui/settings.dart';
import 'package:glacier/glacier.dart';

import 'circle_sample.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final shots = Platform.environment['THEME_SHOTS'] == '1';
  late TokenSheet sheet;

  setUpAll(() async {
    await _fonts();
    sheet = await loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css']);
    installSettingsStyles(sheet);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('ghost/voicefx'), (call) async => null);
  });

  /// [child] in [look] and [theme] in a window of [size].
  Future<void> draw(WidgetTester tester, Widget child, {required Size size, Look look = Look.ghost, String theme = 'light', AppState? state}) async {
    tester.view.physicalSize = size * 2.0;
    tester.view.devicePixelRatio = 2.0;
    tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
    addTearDown(tester.view.reset);
    final app = (state ?? AppState())
      ..setTheme(theme)
      ..setLook(look);
    await tester.pumpWidget(AppScope(
      state: app,
      child: WidgetsApp(
        key: ValueKey('${look.name}-$theme-$size-${child.hashCode}'),
        color: const Color(0xFF4F5BD5),
        debugShowCheckedModeBanner: false,
        pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder b) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => b(c)),
        builder: (context, child) => ListenableBuilder(
          listenable: app,
          builder: (context, _) => GlacierTheme(sheet: sheet, attrs: ghostAttrs(app, 'mobile'), typography: ghostTypography('noto'), child: InkOverrides(child: child!)),
        ),
        home: child,
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> keep(WidgetTester tester, String name) async {
    final element = find.byType(WidgetsApp).evaluate().single;
    await tester.runAsync(() async {
      final image = await captureImage(element);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final file = File('build/themes/circle-list/$name.png');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  for (final look in Look.values) {
    testWidgets('the list draws in ${look.name} on a phone, as a sidebar and across a whole window', (tester) async {
      for (final theme in [if (look.light) 'light', if (look.dark) 'dark']) {
        await draw(tester, CircleList(view: sampleCircleView()), size: const Size(360, 780), look: look, theme: theme);
        expect(tester.takeException(), isNull, reason: '360 in ${look.name} $theme');
        if (shots) await keep(tester, '${look.name}-$theme');
        await draw(tester, CircleList(view: sampleCircleView(wide: true, selected: sampleCircle.spaces.first.seed)), size: const Size(320, 860), look: look, theme: theme);
        expect(tester.takeException(), isNull, reason: 'a 320 sidebar in ${look.name} $theme');
        if (shots) await keep(tester, '${look.name}-$theme-wide');
        await draw(tester, CircleList(view: sampleCircleView(wide: true)), size: const Size(1180, 860), look: look, theme: theme);
        expect(tester.takeException(), isNull, reason: '1180 in ${look.name} $theme');
      }
    });
  }

  testWidgets('the banner gives up its height as the list scrolls up, down to the header alone', (tester) async {
    // Matt, 2026-11-19: "When scrolling up in a sidebar collapse the header background image to only take up the space
    // where the header text and avatar is at the same time as we scroll".
    final m = sampleCircle.manifest;
    // A picture banner (any small PNG will do for its size), and a short screen so the list scrolls.
    const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
    final c = sampleCircle.copyWith(manifest: m.next(extra: {...m.extra, 'bn': png}));
    await draw(tester, CircleList(view: sampleCircleView(circle: c, onBack: () {})), size: const Size(412, 520));
    Rect banner() => tester.getRect(find.byKey(const ValueKey('circle-banner-strip')));
    Rect face() => tester.getRect(find.descendant(of: find.byType(CirclePage), matching: find.byType(CircleFace)).last);
    final list = find.byType(Scrollable).last;
    double scrolled() => tester.state<ScrollableState>(list).position.pixels;
    final full = banner().height;
    final faceAtRest = face();
    // A finger on the list, moved a step at a time, the frame drawn after each.
    Future<void> scroll(double by, {int steps = 10}) async {
      final g = await tester.startGesture(Offset(200, banner().bottom + 40));
      for (var i = 0; i < steps; i++) {
        await g.moveBy(Offset(0, -by / steps));
        await tester.pump();
      }
      await g.up();
      await tester.pumpAndSettle();
    }

    // A little: as much shorter as it was scrolled, as it goes.
    await scroll(30, steps: 3);
    expect(full - banner().height, closeTo(scrolled(), 1), reason: 'shorter by what was scrolled');
    // A lot: down to the header, the face and name inside it with room, and the header itself as it was.
    await scroll(300);
    final small = banner();
    expect(small.height, lessThan(full - 50));
    expect(face().size, faceAtRest.size);
    expect(face().top - small.top, greaterThanOrEqualTo(8));
    expect(small.bottom - face().bottom, greaterThanOrEqualTo(8), reason: 'the face inside it with room, not cut off');
    await keep(tester, 'banner-collapsed');
    // Steady, not shrinking and growing in turn.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(banner().height, small.height);
    }
    // Back at the top it is whole again.
    await scroll(-600, steps: 20);
    expect(scrolled(), 0);
    expect(banner().height, closeTo(full, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a banner is behind the header, taller, with the back arrow, face and name drawn on it', (tester) async {
    // Matt, 2026-11-19: "the background image for the header of circles needs to be taller and the back arrow and
    // other header content should render inside the background image not above it".
    final png = await tester.runAsync(() async {
      final r = ui.PictureRecorder();
      final canvas = Canvas(r);
      const size = Size(240, 80);
      canvas.drawRect(Offset.zero & size, Paint()..shader = ui.Gradient.linear(Offset.zero, const Offset(240, 80), [const Color(0xFF2E7D6B), const Color(0xFFE0A84A)]));
      for (var i = 0; i < 12; i++) {
        canvas.drawCircle(Offset(16.0 + i * 20, 24.0 + (i % 3) * 16), 7, Paint()..color = const Color(0x55FFFFFF));
      }
      final img = await r.endRecording().toImage(240, 80);
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      return base64Encode(bytes!.buffer.asUint8List());
    });
    final m = sampleCircle.manifest;
    expect(png!.length, lessThan(26000), reason: 'small enough for a manifest');
    final c = sampleCircle.copyWith(manifest: m.next(extra: {...m.extra, 'bn': png}));
    for (final theme in ['light', 'dark']) {
      await draw(tester, CircleList(view: sampleCircleView(circle: c, onBack: () {})), size: const Size(412, 892), theme: theme);
      expect(tester.takeException(), isNull);
      final banner = tester.getRect(find.byKey(const ValueKey('circle-banner-strip')));
      final back = tester.getRect(find.bySemanticsLabel('Back'));
      final name = tester.getRect(find.text('Night Owls').first);
      // Set in a little from the screen's edges, rounded (Matt, 2026-11-19: "add just a bit of margin around the sidebar
      // banner header and add some border radius to them so it's not edge to edge").
      // Under the status bar (24 here), not behind its clock and battery (Matt, 2026-11-19: "add a safe area above in
      // the app to give room for the top bar on the phone like the settings batteries and clock").
      expect(banner.top, inInclusiveRange(24 + 4, 24 + 16), reason: 'a little below the status bar');
      expect(banner.left, inInclusiveRange(4, 16), reason: 'in from the left');
      expect(412 - banner.right, inInclusiveRange(4, 16), reason: 'in from the right');
      expect(find.ancestor(of: find.byKey(const ValueKey('circle-banner-strip')), matching: find.byType(ClipRRect)), findsWidgets, reason: 'rounded');
      expect(banner.height, greaterThan(110), reason: 'taller, less its margin and the status bar over it');
      expect(banner.contains(back.center) && banner.contains(name.center), isTrue, reason: 'the header is inside it');
      // Lined up inside it, a margin from every edge (Matt, 2026-11-19: "the header doesn't line up with the header
      // background image correctly"): the circle's face touched, and on the Mac crossed, the picture's rounded top.
      final face = tester.getRect(find.descendant(of: find.byType(CirclePage), matching: find.byType(CircleFace)).last);
      for (final (what, r) in [('face', face), ('name', name)]) {
        expect(r.top - banner.top, greaterThanOrEqualTo(8), reason: '$what clear of the banner\'s top');
        expect(r.left - banner.left, greaterThanOrEqualTo(8), reason: '$what clear of the banner\'s left');
      }
      // The arrow's whole round mark, which shows on hover and press, inside the banner (Matt, 2026-11-19: "when hovering
      // the back arrow the hover state goes over the left edge of the banner"), and almost flush with its top-left corner
      // ("remove the extra padding on the left of the back arrow and some from the top as well so it sits almost flush
      // when hovered with the border of the background image"); on the left only since 2026-11-20.
      expect(back.left - banner.left, inInclusiveRange(1, 4), reason: 'the back arrow\'s hover mark just inside the banner\'s left');
      // Level with the circle's face and name, not at the top corner (Matt, 2026-11-20: "the back arrow should be
      // horizontally centered with the header text on the sidebar").
      expect((back.center.dy - face.center.dy).abs(), lessThanOrEqualTo(1), reason: 'centred on the face beside it');
      expect(back.top - banner.top, greaterThan(4), reason: 'no longer pinned to the top');
      expect(back.bottom, lessThanOrEqualTo(banner.bottom), reason: 'and inside its foot');
      // The picture drawn, for the eye.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump();
      await keep(tester, 'banner-$theme');
    }
  });

  testWidgets('each space says what is going on in it, under its heading, and New space ends the list', (tester) async {
    String? under = 'unset';
    await draw(tester, CircleList(view: sampleCircleView(onNewSpace: ({String? section}) => under = section)), size: const Size(412, 1200));
    expect(find.text('ROOMS'), findsOneWidget);
    expect(find.text('SHARING'), findsOneWidget);
    expect(find.text('3 talking · Maya, Theo, Sam'), findsOneWidget, reason: 'who is in the voice space\'s call');
    expect(find.text('48 files'), findsOneWidget, reason: 'a quiet Files space counts its files');
    expect(find.text('Sam: Added flashcards.zip'), findsOneWidget, reason: 'one with something new says it');
    expect(find.text('Maya: Popcorn is on me'), findsOneWidget);
    expect(find.text('3'), findsWidgets, reason: 'General\'s unread count');
    final add = find.byKey(const ValueKey('circle-new-space'));
    expect(add, findsOneWidget);
    await tester.ensureVisible(add);
    await tester.pump();
    await tester.tap(add);
    expect(under, isNull, reason: 'New space at the foot is under no heading');
  });

  testWidgets('whoever may not change the circle has no New space', (tester) async {
    await draw(tester, CircleList(view: sampleCircleView(canEdit: false)), size: const Size(412, 1200));
    expect(find.byKey(const ValueKey('circle-new-space')), findsNothing);
  });

  testWidgets('a press on a space opens it', (tester) async {
    final lounge = sampleCircle.spaces[1].seed;
    CircleSpaceView? opened;
    await draw(tester, CircleList(view: sampleCircleView(onOpen: (s) => opened = s)), size: const Size(412, 892));
    await tester.tap(find.byKey(ValueKey('circle-space-$lounge')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(opened?.seed, lounge);
  });

  testWidgets('Settings › Appearance offers no circle layout', (tester) async {
    await draw(tester, const SettingsSectionScreen('appearance'), size: const Size(412, 4000));
    expect(find.textContaining(RegExp('circle layout', caseSensitive: false), findRichText: true), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // [view] with other spaces in it, and what a press on one does.
  CircleView withSpaces(CircleView view, List<CircleSpaceView> spaces, {void Function(CircleSpaceView space)? onOpen}) => CircleView(
        circle: view.circle,
        spaces: spaces,
        onOpen: onOpen ?? view.onOpen,
        onNewSpace: view.onNewSpace,
        onSettings: view.onSettings,
        onInvite: view.onInvite,
        onBack: view.onBack,
        onMenu: view.onMenu,
        wide: view.wide,
        canEdit: view.canEdit,
        online: view.online,
      );

  // GMFB-29: "A stage/stream mode: some people speak, many listen, with a listener count".
  testWidgets('a voice space that is a stage says so over who is in it, with how many listen', (tester) async {
    final sample = sampleCircleView();
    CircleSpaceView lounge(int? listening) {
      final s = sample.spaces.firstWhere((s) => s.name == 'Lounge');
      return CircleSpaceView(space: s.space, channel: s.channel, inVoice: const ['Maya Chen', 'Sam'], people: const [CircleVoicePerson(id: 'aa11', name: 'Maya Chen'), CircleVoicePerson(id: 'bb22', name: 'Sam')], listening: listening);
    }

    final seed = lounge(null).seed;
    await draw(tester, CircleList(view: withSpaces(sample, [for (final s in sample.spaces) s.name == 'Lounge' ? lounge(null) : s])), size: const Size(412, 1400));
    expect(find.byKey(ValueKey('circle-voice-$seed-stage')), findsNothing, reason: 'not a stage');
    await draw(tester, CircleList(view: withSpaces(sample, [for (final s in sample.spaces) s.name == 'Lounge' ? lounge(1) : s])), size: const Size(412, 1400));
    expect(find.text('Stage · 1 listening'), findsOneWidget);
    final line = tester.getRect(find.byKey(ValueKey('circle-voice-$seed-stage'))), first = tester.getRect(find.byKey(ValueKey('circle-voice-$seed-aa11')));
    expect(line.bottom, lessThanOrEqualTo(first.top + 1), reason: 'over the people');
    expect(tester.takeException(), isNull);
  });

  // Matt, 2026-11-24: "also show a list of connected users in the sidebar under the voice space with profile pictures
  // and names like discord does".
  testWidgets('who is in a voice space\'s call is listed under it, a face and a name each, and a press opens the space', (tester) async {
    final sample = sampleCircleView();
    CircleSpaceView? opened;
    CircleSpaceView withPeople(CircleSpaceView s) => s.name != 'Lounge'
        ? s
        : CircleSpaceView(
            space: s.space,
            channel: s.channel,
            inVoice: const ['You', 'Maya Chen', 'Sam'],
            people: const [CircleVoicePerson(id: 'me', name: 'You'), CircleVoicePerson(id: 'aa11', name: 'Maya Chen'), CircleVoicePerson(id: 'bb22', name: 'Sam')],
            here: false,
          );
    final view = withSpaces(sample, [for (final s in sample.spaces) withPeople(s)], onOpen: (s) => opened = s);
    await draw(tester, CircleList(view: view), size: const Size(412, 1400));
    final lounge = view.spaces.firstWhere((s) => s.name == 'Lounge');
    final tile = tester.getRect(find.byKey(ValueKey('circle-space-${lounge.seed}')));
    // One row each, in the call's order, under the space and inside its name's column.
    final rows = [for (final id in ['me', 'aa11', 'bb22']) tester.getRect(find.byKey(ValueKey('circle-voice-${lounge.seed}-$id')))];
    expect(rows.first.top, greaterThanOrEqualTo(tile.bottom - 1), reason: 'under the space');
    for (var i = 1; i < rows.length; i++) {
      expect(rows[i].top, greaterThanOrEqualTo(rows[i - 1].bottom - 1), reason: 'one under the other');
    }
    final name = tester.getRect(find.descendant(of: find.byKey(ValueKey('circle-space-${lounge.seed}')), matching: find.text('Lounge')));
    final people = find.byType(CircleVoicePeople);
    expect(people, findsOneWidget, reason: 'only the space with someone in it');
    for (final who in ['You', 'Maya Chen', 'Sam']) {
      final at = tester.getRect(find.descendant(of: people, matching: find.text(who)));
      expect(at.left, greaterThan(name.left), reason: '$who set in under the space\'s name');
    }
    expect(find.descendant(of: people, matching: find.byType(Avatar)), findsNWidgets(3), reason: 'a face each');
    // Each face starts where the space's name does (Matt, 2026-11-25: "left align the users in the list of users
    // connected a call with the title text"): the ring's room round it is not a margin before it.
    for (final face in tester.widgetList<Avatar>(find.descendant(of: people, matching: find.byType(Avatar)))) {
      expect(tester.getRect(find.byWidget(face)).left, moreOrLessEquals(name.left, epsilon: 0.5), reason: 'the face under the name\'s first letter');
    }
    // The space's own line counts them and leaves their names to the rows.
    expect(circleSpaceLine(lounge), '3 talking');
    expect(find.text('3 talking'), findsOneWidget);
    expect(find.textContaining('3 talking ·'), findsNothing);
    // A press on someone opens the space they are in.
    await tester.tap(find.descendant(of: people, matching: find.text('Maya Chen')));
    await tester.pump();
    expect(opened?.name, 'Lounge');
    expect(tester.takeException(), isNull);
    await keep(tester, 'voice-people');
  });

  testWidgets('the music played to a call is listed last under its space, cover and song', (tester) async {
    final sample = sampleCircleView();
    CircleSpaceView with_(CircleSpaceView s, {({String song, String? cover})? music}) => s.name != 'Lounge'
        ? s
        : CircleSpaceView(space: s.space, channel: s.channel, inVoice: const ['You'], people: const [CircleVoicePerson(id: 'me', name: 'You')], music: music);
    await draw(tester, CircleList(view: withSpaces(sample, [for (final s in sample.spaces) with_(s)])), size: const Size(412, 1400));
    expect(find.textContaining('Spotify', findRichText: true), findsNothing);
    final view = withSpaces(sample, [for (final s in sample.spaces) with_(s, music: (song: 'A song with a name far too long for the width of a list of spaces', cover: null))]);
    await draw(tester, CircleList(view: view), size: const Size(412, 1400));
    final seed = view.spaces.firstWhere((s) => s.name == 'Lounge').seed;
    final me = tester.getRect(find.byKey(ValueKey('circle-voice-$seed-me'))), music = tester.getRect(find.byKey(ValueKey('circle-voice-$seed-music')));
    expect(music.top, greaterThanOrEqualTo(me.bottom - 1));
    expect(music.height, moreOrLessEquals(me.height, epsilon: 1), reason: 'one line, as a person\'s');
    expect(find.byType(VoiceRipples), findsNWidgets(2), reason: 'a face and the music, each with rings');
    expect(circleSpaceLine(view.spaces.firstWhere((s) => s.name == 'Lounge')), 'You\'re talking', reason: 'music is nobody talking');
    expect(tester.takeException(), isNull);
    await keep(tester, 'voice-music');
  });

  // GMFB-66: "It would be nice to show what users are streaming and or sharing video".
  testWidgets('someone with their camera on or sharing their screen has a mark after their name', (tester) async {
    final sample = sampleCircleView();
    final view = withSpaces(sample, [
      for (final s in sample.spaces)
        s.name != 'Lounge'
            ? s
            : CircleSpaceView(space: s.space, channel: s.channel, inVoice: const ['Maya Chen', 'Sam', 'Kai'], people: const [
                CircleVoicePerson(id: 'aa11', name: 'Maya Chen', camera: true),
                CircleVoicePerson(id: 'bb22', name: 'Sam', screen: true),
                CircleVoicePerson(id: 'cc33', name: 'Kai'),
              ]),
    ]);
    await draw(tester, CircleList(view: view), size: const Size(412, 1400));
    final seed = view.spaces.firstWhere((s) => s.name == 'Lounge').seed;
    final camera = find.byKey(ValueKey('circle-voice-$seed-aa11-camera')), screen = find.byKey(ValueKey('circle-voice-$seed-bb22-screen'));
    expect(camera, findsOneWidget);
    expect(screen, findsOneWidget);
    expect(find.byKey(ValueKey('circle-voice-$seed-bb22-camera')), findsNothing, reason: 'a screen, not a camera too');
    expect(find.byKey(ValueKey('circle-voice-$seed-cc33-camera')), findsNothing);
    expect(find.byKey(ValueKey('circle-voice-$seed-cc33-screen')), findsNothing);
    final people = find.byType(CircleVoicePeople);
    expect(tester.getRect(camera).left, greaterThan(tester.getRect(find.descendant(of: people, matching: find.text('Maya Chen'))).left), reason: 'after the name');
    expect(tester.getRect(camera).right, lessThanOrEqualTo(412), reason: 'inside the list');
    expect(tester.takeException(), isNull);
    await keep(tester, 'voice-camera-screen');
  });

  testWidgets('a crowded call lists a dozen and counts the rest', (tester) async {
    final sample = sampleCircleView();
    final crowd = [for (var i = 0; i < 15; i++) CircleVoicePerson(id: 'p$i', name: 'Person $i')];
    final view = withSpaces(sample, [
      for (final s in sample.spaces)
        s.name != 'Lounge' ? s : CircleSpaceView(space: s.space, channel: s.channel, inVoice: [for (final p in crowd) p.name], people: crowd),
    ]);
    await draw(tester, CircleList(view: view), size: const Size(412, 1800));
    expect(find.text('Person 11'), findsOneWidget);
    expect(find.text('Person 12'), findsNothing);
    expect(find.text('and 3 more'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('a space\'s line: talking, then files, then the newest message', () {
    final v = sampleCircleView();
    String? line(String name) => circleSpaceLine(v.spaces.firstWhere((s) => s.name == name));
    expect(line('Lounge'), '3 talking · Maya, Theo, Sam');
    expect(line('Photos'), '48 files');
    expect(line('Drop box'), 'Sam: Added flashcards.zip');
    expect(line('Study room'), isNull);
  });

  test('one person talking reads as a sentence, "You\'re talking" when it is you', () {
    expect(talkingAlone('Maya'), 'Maya is talking');
    expect(talkingAlone('You'), 'You\'re talking');
  });
}

/// The app's fonts, so the pictures show words.
Future<void> _fonts() async {
  Future<void> family(String name, String file) async {
    final loader = FontLoader(name)..addFont(File(file).readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
    await loader.load();
  }

  await family('Inter Variable', 'assets/fonts/InterVariable-latin.ttf');
  await family('JetBrains Mono Variable', 'assets/fonts/JetBrainsMonoVariable-latin.ttf');
  await family('Arimo', 'assets/fonts/ArimoVariable.ttf');
  await family('Ghost Emoji Noto', 'assets/emoji/NotoColor.ttf');
}
