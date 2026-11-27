import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStream;
import 'package:ghost_messaging/app_seen.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/main.dart' show InkOverrides, ghostTypography;
import 'package:ghost_messaging/net/hub_carrier.dart' show RoomEvent;
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/ui/call_float.dart';
import 'package:ghost_messaging/ui/call_pip.dart';
import 'package:ghost_messaging/ui/dialup/title_bar.dart';
import 'package:ghost_messaging/ui/shell.dart';
import 'package:ghost_messaging/ui/space_designs/space_design.dart' show SpaceCallPage;
import 'package:ghost_messaging/ui/tile_grid.dart' show VideoShapes;
import 'package:ghost_messaging/ui/voice_screen.dart';
import 'package:ghost_messaging/voice/channels.dart' show Voice;
import 'package:ghost_messaging/voice/rtc.dart' show RtcMedia;
import 'package:ghost_messaging/voice/voice.dart';
import 'package:glacier/glacier.dart';

import 'support/list_harness.dart' show ListPhone;
import 'support/space_call_harness.dart' show SpaceHarness;

/// The call's picture floating over the app (GMFB-64, Kevin, Android 0.12.29: "Streaming or video calling would be nice
/// if there were a pop out option"; Matt, 2026-11-25: "Please go ahead take care of the pop out video player as well"),
/// and the Dart half of Android's picture in picture. Run with --update-goldens, the pictures go to build/popout/.

class _Stream implements MediaStream {
  _Stream(this.id);
  @override
  final String id;
  @override
  String get ownerTag => 'test';
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// flutter_webrtc's renderers stood in for: which stream each texture was told to draw, while it lives. [overlaps] is
/// every time one stream was put on a second living renderer.
class _Renderers {
  var next = 1;
  final live = <int, String>{};
  final overlaps = <String>[];
  final made = <int>[];
  final log = <String>[];

  void install() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('FlutterWebRTC.Method'), (call) async {
      final args = (call.arguments as Map?) ?? const {};
      log.add('${call.method} $args');
      switch (call.method) {
        case 'createVideoRenderer':
          made.add(next);
          return {'textureId': next++};
        case 'videoRendererSetSrcObject':
          final id = args['streamId'] as String;
          final tex = args['textureId'] as int;
          if (id.isNotEmpty && live.entries.any((e) => e.key != tex && e.value == id)) overlaps.add('$id on $tex beside ${live.entries.where((e) => e.value == id).map((e) => e.key)}');
          live[tex] = id;
        case 'videoRendererDispose':
          live.remove(args['textureId'] as int);
      }
      return null;
    });
    m.setMockStreamHandler(const EventChannel('FlutterWebRTC.Event'), MockStreamHandler.inline(onListen: (_, _) {}));
    for (var i = 1; i < 80; i++) {
      m.setMockStreamHandler(EventChannel('FlutterWebRTC/Texture$i'), MockStreamHandler.inline(onListen: (_, _) {}));
    }
  }

  int drawing(String stream) => live.values.where((s) => s == stream).length;
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

class _Computer implements SmsCalls {
  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async => null;
}

const _names = {'a': 'Maya Chen', 'b': 'Sam Ortiz', 'c': 'Riley'};

/// In [c]'s call as Voice.join leaves it: [video] the ids with a camera on (their pictures arrived), [screens] those
/// sharing their screen, [mine] this device's own camera.
VoiceSession _call(VoiceChannel c, {Set<String> people = const {'a'}, Set<String> video = const {'a'}, Set<String> screens = const {}, bool mine = false}) {
  final v = Voice.instance;
  final media = RtcMedia();
  v.media = media;
  final s = VoiceSession(channel: c, route: _NoRoute(), media: _NoMedia(), name: 'Me');
  for (final id in people) {
    s.members[id] = VoiceMember(id, name: _names[id]!, video: video.contains(id) || screens.contains(id), screen: screens.contains(id));
  }
  v.session = s;
  media.remote.value = {for (final id in people) if (video.contains(id) || screens.contains(id)) id: _Stream('s-$id')};
  if (mine) media.localVideo.value = _Stream('s-me');
  v.putLook(c.room, people.toList());
  return s;
}

/// Someone leaves the call, or turns their picture off.
void _gone(String id, {bool leave = true}) {
  final v = Voice.instance;
  final s = v.session!;
  if (leave) {
    s.members.remove(id);
  } else {
    s.members[id] = VoiceMember(id, name: _names[id]!);
  }
  v.media!.remote.value = {...v.media!.remote.value}..remove(id);
  v.putLook(s.channel.room, s.members.keys.toList());
}

late TokenSheet _sheet;

/// The app's frame as the phone (or, [computer], the Mac) draws it, [size] big, light or [dark], [look].
Future<AppState> _pump(WidgetTester tester, {Size size = const Size(412, 892), bool dark = false, Look look = Look.ghost, bool computer = false, AppState? state}) async {
  tester.view.physicalSize = size * 2.0;
  tester.view.devicePixelRatio = 2.0;
  tester.view.padding = computer ? FakeViewPadding.zero : const FakeViewPadding(top: 48, bottom: 32);
  addTearDown(tester.view.reset);
  final app = state ??
      (AppState()
        ..setTheme(dark ? 'dark' : 'light')
        ..setLook(look));
  final was = Sms.calls;
  if (computer) {
    Sms.calls = _Computer();
    addTearDown(() => Sms.calls = was);
  }
  await tester.pumpWidget(AppScope(
    state: app,
    child: WidgetsApp(
      key: ValueKey('$size$dark$look$computer'),
      color: const Color(0xFF4F5BD5),
      debugShowCheckedModeBanner: false,
      pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder b) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => b(c)),
      builder: (context, child) => GlacierTheme(
        sheet: _sheet,
        attrs: ghostAttrs(app, computer ? 'desktop' : 'mobile'),
        typography: ghostTypography('noto'),
        child: InkOverrides(child: GlacierToastProvider(child: CallPipFrame(child: child!))),
      ),
      home: const AppShell(),
    ),
  ));
  await _settle(tester);
  return app;
}

Future<void> _settle(WidgetTester tester, [int frames = 14]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    // The platform's answers (a renderer's stream cancelled) come in real time.
    if (i % 4 == 0) await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
  }
}

/// Keeps the frame as build/popout/[name].png, when run with --update-goldens.
Future<void> _shot(WidgetTester tester, String name) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
  await _settle(tester, 6);
  if (autoUpdateGoldenFiles) await expectLater(find.byType(WidgetsApp), matchesGoldenFile('../build/popout/$name.png'));
}

final _float = find.byKey(const ValueKey('call-float'));
final _tile = find.byKey(const ValueKey('call-float-tile'));
String? _floatName(WidgetTester tester) => _float.evaluate().isEmpty ? null : tester.widget<Text>(find.descendant(of: _float, matching: find.byKey(const ValueKey('call-float-name')))).data;
bool _bannerShown() => find.descendant(of: find.byType(CallBanner), matching: find.byType(GlacierPressable)).evaluate().isNotEmpty;

/// Shows the picture's buttons with a tap, once those a tap showed before have gone again.
Future<void> _buttons(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.tap(_tile);
  await _settle(tester, 4);
}

Future<void> _press(WidgetTester tester, String label) async {
  await tester.tap(find.bySemanticsLabel(label).last);
  await _settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Renderers renderers;
  final film = VoiceChannel.ofGroup('g-film', 'Film night');

  setUp(() async {
    ListPhone(const []).install();
    renderers = _Renderers()..install();
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('ghost/voicefx'), (call) async => null);
    m.setMockMethodCallHandler(CallPip.channel, (call) async => null);
    CallFloat.instance.reset();
    StreamClaims.reset();
    AppSeen.set(true);
  });
  tearDown(() async {
    final v = Voice.instance;
    v.session = null;
    v.media = null;
    v.putLook(film.room, const []);
    VideoShapes.changes.value = const {};
  });

  group('which picture', () {
    CallPicture p(String id, {bool screen = false, bool me = false}) => CallPicture(id: id, name: id, stream: _Stream('$id-${screen ? 's' : 'c'}'), screen: screen, me: me);
    test('a shared screen first, then whoever talks, then the latest camera, and your own only when it is all there is', () {
      final maya = p('a'), sam = p('b'), samScreen = p('b', screen: true), me = p('me', me: true), myScreen = p('me', screen: true, me: true);
      final order = {maya.key: 1, sam.key: 2, me.key: 3, samScreen.key: 4, myScreen.key: 5};
      expect(pickPicture([me, maya, sam, samScreen], order: order, talker: 'a'), samScreen, reason: 'a shared screen before anyone talking');
      expect(pickPicture([me, maya, sam], order: order, talker: 'a'), maya, reason: 'Maya is talking, though Sam\'s camera came later');
      expect(pickPicture([me, maya, sam], order: order), sam, reason: 'nobody talking: the latest camera');
      expect(pickPicture([me, maya], order: order), maya, reason: 'never your own while there is another');
      expect(pickPicture([myScreen, maya], order: order), maya, reason: 'not even your own screen');
      expect(pickPicture([me], order: order), me, reason: 'your own where it is all there is');
      expect(pickPicture(const []), isNull);
      // An open space pops out a shared screen alone.
      expect(pickPicture([me, maya, sam], order: order, screensOnly: true), isNull);
      expect(pickPicture([maya, samScreen], order: order, screensOnly: true), samScreen);
    });
  });

  testWidgets('leaving a video call\'s page leaves its picture floating, in place of the call\'s bar; coming back takes it away', (tester) async {
    _sheet = (await SpaceHarness.load(tester)).sheet;
    await _pump(tester);
    final shell = AppShellState.live!;
    _call(film);
    shell.go('voice');
    await _settle(tester);
    expect(find.byType(CallPanel), findsOneWidget);
    expect(_float, findsNothing, reason: 'on the call\'s page nothing floats');
    expect(renderers.drawing('s-a'), 1, reason: 'the call\'s page draws Maya');

    shell.close();
    await _settle(tester);
    expect(_float, findsOneWidget, reason: 'left the page: the picture floats');
    expect(_floatName(tester), 'Maya Chen');
    expect(_bannerShown(), isFalse, reason: 'the picture stands in for the call\'s bar');
    expect(renderers.drawing('s-a'), 1, reason: 'drawn once, by the picture');
    await _shot(tester, 'phone-light');

    // Its buttons, shown by a tap.
    await _buttons(tester);
    await _shot(tester, 'phone-light-buttons');

    shell.go('voice');
    await _settle(tester);
    expect(_float, findsNothing, reason: 'back on the call\'s page');
    expect(renderers.drawing('s-a'), 1);
    expect(renderers.overlaps, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a voice-only call keeps its bar and never floats', (tester) async {
    _sheet = (await SpaceHarness.load(tester)).sheet;
    await _pump(tester);
    _call(film, video: const {});
    await _settle(tester);
    expect(_float, findsNothing);
    expect(_bannerShown(), isTrue, reason: 'the call\'s bar, as before');
    expect(CallFloat.instance.canPopOut, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('one stream is never on two renderers: a call\'s page kept under another lets go of it while it floats', (tester) async {
    _sheet = (await SpaceHarness.load(tester)).sheet;
    await _pump(tester);
    final shell = AppShellState.live!;
    _call(film);
    shell.go('voice');
    await _settle(tester);
    final pageTexture = renderers.live.entries.single.key;

    // A page over the call's, in the pane: the call's is still built under it, out of sight.
    final nav = Navigator.of(tester.element(find.byType(CallPanel)));
    nav.push(PageRouteBuilder<void>(pageBuilder: (context, _, _) => const ColoredBox(color: Color(0xFFFFFFFF), child: Center(child: Text('Another page')))));
    await _settle(tester);
    expect(find.byType(CallPanel, skipOffstage: false), findsOneWidget, reason: 'the call\'s page is kept');
    expect(_float, findsOneWidget, reason: 'covered, the call\'s page is left');
    expect(renderers.live.containsKey(pageTexture), isFalse, reason: 'the page let go of its renderer');
    expect(renderers.drawing('s-a'), 1, reason: 'the picture holds the only one');
    expect(StreamClaims.heldOf('s-a'), 1);

    nav.pop();
    await _settle(tester);
    expect(_float, findsNothing);
    expect(renderers.drawing('s-a'), 1, reason: 'the page took it back');
    expect(StreamClaims.heldOf('s-a'), 1);
    expect(renderers.overlaps, isEmpty, reason: 'never two at once');
    expect(tester.takeException(), isNull);
  });

  testWidgets('dragged anywhere it snaps to the nearest corner, inside the screen and clear of the bars, and the corner is kept', (tester) async {
    _sheet = (await SpaceHarness.load(tester)).sheet;
    final app = await _pump(tester);
    _call(film);
    await _settle(tester);
    final t = tester.element(_float).tokens;
    final window = tester.view.physicalSize / tester.view.devicePixelRatio;
    final pad = MediaQuery.paddingOf(tester.element(_float));
    final area = CallFloatLayer.areaIn(window, pad, t);
    Rect at() => tester.getRect(_tile);
    expect(at().topRight, area.topRight, reason: 'it starts at the top right');

    await tester.drag(_tile, const Offset(-260, 420));
    await _settle(tester);
    expect(app.choice(CallFloat.cornerPref, ''), 'bl');
    expect(at().bottomLeft, area.bottomLeft);

    // Thrown far past the edge: still inside.
    await tester.drag(_tile, const Offset(2000, -2000));
    await _settle(tester);
    expect(app.choice(CallFloat.cornerPref, ''), 'tr');
    expect(area.contains(at().topLeft) && area.contains(at().bottomRight - const Offset(0.1, 0.1)), isTrue, reason: '${at()} in $area');
    expect(at().top, greaterThanOrEqualTo(pad.top + 64), reason: 'under the title bar');
    expect(at().bottom, lessThanOrEqualTo(window.height - pad.bottom - 88), reason: 'above the composer and the dock');

    // Kept: a picture floated again starts where it was left.
    await tester.drag(_tile, const Offset(0, 400));
    await _settle(tester);
    expect(app.choice(CallFloat.cornerPref, ''), 'br');
    Voice.instance.session = null;
    Voice.instance.putLook(film.room, const []);
    await _settle(tester);
    expect(_float, findsNothing);
    _call(film);
    await _settle(tester);
    expect(at().bottomRight, area.bottomRight);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Close puts it away for this call; the bar\'s Pop out and the call\'s own bring it back', (tester) async {
    _sheet = (await SpaceHarness.load(tester)).sheet;
    await _pump(tester);
    final shell = AppShellState.live!;
    _call(film);
    await _settle(tester);
    await _buttons(tester);
    await _press(tester, FloatWords.close);
    expect(_float, findsNothing);
    expect(Voice.instance.session, isNotNull, reason: 'the call goes on');
    expect(_bannerShown(), isTrue, reason: 'the bar stands in');
    expect(find.byKey(const ValueKey('call-banner-pop-out')), findsOneWidget);
    expect(renderers.drawing('s-a'), 0, reason: 'nothing draws Maya now');

    await tester.tap(find.byKey(const ValueKey('call-banner-pop-out')));
    await _settle(tester);
    expect(_float, findsOneWidget, reason: 'popped out again from the bar');

    // Closed again, then Pop out on the call's own page: off the page, with the picture.
    await _buttons(tester);
    await _press(tester, FloatWords.close);
    shell.go('voice');
    await _settle(tester);
    expect(find.byType(CallPanel), findsOneWidget);
    await _press(tester, FloatWords.popOut);
    expect(find.byType(CallPanel), findsNothing, reason: 'the call\'s page is left');
    expect(_float, findsOneWidget);

    // A call of its own after this one starts with its picture.
    await _buttons(tester);
    await _press(tester, FloatWords.close);
    Voice.instance.session = null;
    Voice.instance.putLook(film.room, const []);
    await _settle(tester);
    _call(VoiceChannel.ofGroup('g-other', 'Lunch'));
    await _settle(tester);
    expect(_float, findsOneWidget, reason: 'closed for the last call, not this');
    expect(renderers.overlaps, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('its buttons: back to the call, mute and leave', (tester) async {
    _sheet = (await SpaceHarness.load(tester)).sheet;
    await _pump(tester);
    final s = _call(film);
    await _settle(tester);
    await _buttons(tester);
    await _press(tester, 'Mute');
    expect(s.muted, isTrue);
    expect(find.descendant(of: _float, matching: find.byKey(const ValueKey('call-float-my-mic'))), findsOneWidget, reason: 'it says you are muted');
    await _buttons(tester);
    await _press(tester, 'Unmute');
    expect(s.muted, isFalse);

    await _buttons(tester);
    await _press(tester, FloatWords.back);
    expect(find.byType(CallPanel), findsOneWidget, reason: 'the call\'s page');
    expect(_float, findsNothing);

    AppShellState.live!.close();
    await _settle(tester);
    await _buttons(tester);
    await _press(tester, FloatWords.leave);
    expect(Voice.instance.session, isNull, reason: 'out of the call');
    expect(_float, findsNothing);
    expect(renderers.drawing('s-a'), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('it follows the call: a shared screen over a camera, whoever talks, the next when one leaves, gone when it ends', (tester) async {
    _sheet = (await SpaceHarness.load(tester)).sheet;
    await _pump(tester);
    _call(film, people: const {'a', 'b', 'c'}, video: const {'a', 'c'}, screens: const {'b'}, mine: true);
    await _settle(tester);
    expect(_floatName(tester), 'Sam Ortiz\'s screen', reason: 'a shared screen first');

    _gone('b', leave: false);
    await _settle(tester);
    expect(_floatName(tester), 'Riley', reason: 'the latest camera, not your own');

    Voice.instance.media!.levels.value = const {'a': 0.4};
    await _settle(tester);
    expect(_floatName(tester), 'Maya Chen', reason: 'Maya is talking');
    Voice.instance.media!.levels.value = const {};
    await _settle(tester);
    expect(_floatName(tester), 'Maya Chen', reason: 'and keeps it between her words');

    _gone('a');
    await _settle(tester);
    expect(_floatName(tester), 'Riley', reason: 'Maya left: the next');
    _gone('c');
    await _settle(tester);
    expect(_floatName(tester), 'You', reason: 'your own, now it is all there is');
    expect(renderers.drawing('s-a'), 0);
    expect(renderers.drawing('s-c'), 0);

    Voice.instance.media!.localVideo.value = null;
    await _settle(tester);
    expect(_float, findsNothing, reason: 'no pictures left');
    expect(_bannerShown(), isTrue, reason: 'the bar again');

    _call(film);
    await _settle(tester);
    expect(_float, findsOneWidget);
    Voice.instance.session = null;
    Voice.instance.putLook(film.room, const []);
    await _settle(tester);
    expect(_float, findsNothing, reason: 'the call ended');
    expect(renderers.live, isEmpty, reason: 'every renderer let go');
    expect(renderers.overlaps, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an open space pops out a shared screen alone', (tester) async {
    _sheet = (await SpaceHarness.load(tester)).sheet;
    await _pump(tester);
    final floor = VoiceChannel.make('The floor', kind: SpaceKind.open);
    _call(floor, people: const {'a', 'b'}, video: const {'a'});
    await _settle(tester);
    expect(_float, findsNothing, reason: 'a camera on the floor is not popped out');
    Voice.instance.session = null;
    Voice.instance.putLook(floor.room, const []);
    await _settle(tester);
    _call(floor, people: const {'a', 'b'}, video: const {'a'}, screens: const {'b'});
    await _settle(tester);
    expect(_floatName(tester), 'Sam Ortiz\'s screen');
    expect(tester.takeException(), isNull);
  });

  testWidgets('away, nothing is drawn', (tester) async {
    _sheet = (await SpaceHarness.load(tester)).sheet;
    await _pump(tester);
    _call(film);
    await _settle(tester);
    expect(_float, findsOneWidget);
    AppSeen.set(false);
    await _settle(tester);
    expect(_float, findsNothing);
    expect(renderers.drawing('s-a'), 0, reason: 'its renderer let go while the app is away: ${renderers.log}');
    AppSeen.set(true);
    await _settle(tester);
    expect(_float, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a narrow phone: small, and inside it', (tester) async {
    _sheet = (await SpaceHarness.load(tester)).sheet;
    await _pump(tester, size: const Size(340, 700));
    _call(film);
    await _settle(tester);
    final r = tester.getRect(_tile);
    expect(r.width, lessThanOrEqualTo(340 * 0.46));
    expect(r.left, greaterThanOrEqualTo(0));
    expect(r.right, lessThanOrEqualTo(340));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a space\'s call: Pop out in its menu', (tester) async {
    _sheet = (await SpaceHarness.load(tester)).sheet;
    await _pump(tester);
    final shell = AppShellState.live!;
    _call(VoiceChannel.make('Friday hang'));
    shell.go('voice');
    await _settle(tester);
    expect(find.byType(SpaceCallPage), findsOneWidget);
    expect(_float, findsNothing);
    await tester.tap(find.bySemanticsLabel(RegExp('^More')).last);
    await _settle(tester);
    await _press(tester, FloatWords.popOut);
    expect(find.byType(SpaceCallPage), findsNothing);
    expect(_float, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Dial-Up: a small window of its own, its tools always there', (tester) async {
    _sheet = (await SpaceHarness.load(tester)).sheet;
    await _pump(tester, look: Look.dialup);
    final s = _call(film);
    await _settle(tester);
    expect(find.descendant(of: _float, matching: find.byType(TitleBar)), findsOneWidget);
    await _shot(tester, 'phone-dialup');
    await _press(tester, 'Mute');
    expect(s.muted, isTrue, reason: 'no tap first: the tools are always there');
    await _press(tester, FloatWords.close);
    expect(_float, findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets('on a computer, ${dark ? 'dark' : 'light'}: a small size and a large', (tester) async {
      _sheet = (await SpaceHarness.load(tester)).sheet;
      final app = await _pump(tester, size: const Size(1280, 800), dark: dark, computer: true);
      _call(film, people: const {'a', 'b'}, video: const {'a'}, screens: const {'b'});
      VideoShapes.say('s-b', 16 / 9);
      await _settle(tester);
      expect(Sms.computer, isTrue);
      final small = tester.getRect(_tile);
      expect(small.width, 240);
      await _shot(tester, 'desktop-${dark ? 'dark' : 'light'}');
      await _buttons(tester);
      await _press(tester, FloatWords.larger);
      expect(app.choice(CallFloat.largePref, ''), '1');
      final large = tester.getRect(_tile);
      expect(large.width, 400);
      expect(large.height, closeTo(400 / (16 / 9), 0.5), reason: 'the screen\'s own shape');
      await _shot(tester, 'desktop-${dark ? 'dark' : 'light'}-large');
      await _buttons(tester);
      await _press(tester, FloatWords.smaller);
      expect(tester.getRect(_tile).width, 240);
      expect(tester.takeException(), isNull);
    });
  }

  group('Android\'s picture in picture, from Dart', () {
    late List<Map<Object?, Object?>> told;
    setUp(() {
      told = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(CallPip.channel, (call) async {
        if (call.method == 'pip') told.add(Map.of(call.arguments as Map));
        return null;
      });
    });
    tearDown(CallPip.instance.stop);

    Future<void> said(String method, Map<String, Object?> args) async {
      final codec = const StandardMethodCodec();
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(CallPip.channel.name, codec.encodeMethodCall(MethodCall(method, args)), (_) {});
    }

    testWidgets('told the picture as a video starts, changes shape and stops; muting; nothing outside a video call', (tester) async {
      CallPip.instance.follow();
      await tester.pump();
      expect(told, isEmpty, reason: 'no call: nothing said');
      final v = Voice.instance;
      final s = _call(film, video: const {});
      await tester.pump();
      expect(told, isEmpty, reason: 'a voice-only call: nothing said, so it never goes into picture in picture');

      v.session = null;
      v.putLook(film.room, const []);
      _call(film);
      await tester.pump();
      expect(told.last, {'on': true, 'w': 133, 'h': 100, 'muted': false, 'screen': false}, reason: 'a camera\'s 4:3 until a frame says');
      VideoShapes.say('s-a', 9 / 16);
      await tester.pump();
      expect(told.last, {'on': true, 'w': 56, 'h': 100, 'muted': false, 'screen': false}, reason: 'an upright phone camera');
      final n = told.length;
      VideoShapes.say('s-a', 9 / 16);
      await tester.pump();
      expect(told, hasLength(n), reason: 'nothing said twice');

      v.session!.setMuted(true);
      await tester.pump();
      expect(told.last['muted'], isTrue, reason: 'the Mute button shows Unmute');

      _gone('a', leave: false);
      await tester.pump();
      expect(told.last, {'on': false}, reason: 'the picture stopped: no picture in picture');
      expect(s, isNot(v.session));
    });

    testWidgets('a screen is wide and held to what Android allows', (tester) async {
      CallPip.instance.follow();
      _call(film, people: const {'b'}, video: const {}, screens: const {'b'});
      await tester.pump();
      expect(told.last, {'on': true, 'w': 178, 'h': 100, 'muted': false, 'screen': true});
      VideoShapes.say('s-b', 5.0);
      await tester.pump();
      expect(told.last['w'], 239, reason: '2.39:1 at most');
      Voice.instance.session = null;
      Voice.instance.putLook(film.room, const []);
      await tester.pump();
      expect(told.last, {'on': false}, reason: 'the call ended');
    });

    testWidgets('its Mute and Leave, and the app drawn as the picture alone while in', (tester) async {
      _sheet = (await SpaceHarness.load(tester)).sheet;
      CallPip.instance.follow();
      await _pump(tester);
      final s = _call(film);
      await _settle(tester);
      expect(_float, findsOneWidget);

      await said('changed', {'in': true});
      await _settle(tester);
      expect(find.byKey(const ValueKey('pip-picture')), findsOneWidget);
      expect(_float, findsNothing, reason: 'the window shows it instead');
      expect(find.byType(AppShell), findsNothing, reason: 'nothing of the app is seen');
      expect(find.byType(AppShell, skipOffstage: false), findsOneWidget, reason: 'it is kept under the picture');
      expect(renderers.drawing('s-a'), 1, reason: 'the window\'s picture, once');
      await _shot(tester, 'phone-pip');

      await said('action', {'do': 'mute'});
      await tester.pump();
      expect(s.muted, isTrue);
      await said('action', {'do': 'mute'});
      await tester.pump();
      expect(s.muted, isFalse);

      await said('changed', {'in': false});
      await _settle(tester);
      expect(find.byKey(const ValueKey('pip-picture')), findsNothing);
      expect(find.byType(AppShell), findsOneWidget, reason: 'the app comes back as it was');
      expect(_float, findsOneWidget);

      await said('action', {'do': 'leave'});
      await _settle(tester);
      expect(Voice.instance.session, isNull);
      expect(told.last, {'on': false});
      expect(renderers.overlaps, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });
}
