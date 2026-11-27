import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/hub_carrier.dart' show RoomEvent;
import 'package:ghost_messaging/ui/screen_share.dart';
import 'package:ghost_messaging/ui/space_designs/space_design.dart';
import 'package:ghost_messaging/ui/space_designs/telegram.dart';
import 'package:ghost_messaging/ui/voice_screen.dart' show showPerson;
import 'package:ghost_messaging/ui/window_chrome.dart' show MacChrome;
import 'package:ghost_messaging/voice/channels.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/space_call_harness.dart';

/// What is shown large in a call (GMFB-27, "Viewers see the share as its own large tile, can pin it, and full-screen
/// it"): full screen for a shared screen, over the whole window on a computer, and Esc out of it; Pin, which keeps
/// one person's picture large on this device until Unpin; and the same stage in a friend's or a group's call, where a
/// shared screen was only a tile. And a stage's listener count, said to everyone in it (GMFB-29).
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

/// A call with Maya sharing her screen, Sam's camera on and Riley with neither.
VoiceSession _call() {
  final s = VoiceSession(channel: VoiceChannel.make('Friday hang'), route: _NoRoute(), media: _NoMedia(), name: 'Me')
    ..members['a'] = const VoiceMember('a', name: 'Maya Chen', video: true, screen: true)
    ..members['b'] = const VoiceMember('b', name: 'Sam Ortiz', video: true)
    ..members['c'] = const VoiceMember('c', name: 'Riley');
  Voice.instance.session = s;
  return s;
}

void main() {
  final native = <String>[];
  setUp(() {
    native.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('com.alexmercerind/media_kit_video'), (call) async {
      native.add(call.method);
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('com.alexmercerind/media_kit_video'), null);
    Voice.instance.session = null;
    CallPin.clear();
    MacChrome.covered.value = false;
  });

  testWidgets('a shared screen goes full screen over the whole window on a computer, and Esc or the button leaves it', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();
    const picture = ColoredBox(key: ValueKey('picture'), color: Color(0xFF224466), child: SizedBox.expand());
    await h.shoot(
      tester,
      Row(children: [
        const SizedBox(width: 320, child: ColoredBox(color: Color(0xFFEEEEEE), child: Center(child: Text('The list')))),
        Expanded(child: ScreenStage(name: 'Maya Chen', stream: null, picture: picture, desk: true, onBack: () {})),
      ]),
      'call-stage-full',
      size: SpaceHarness.computer,
    );
    Rect at() => tester.getRect(find.byKey(const ValueKey('picture')));
    expect(at().left, 320);
    await tester.tap(find.bySemanticsLabel('Full screen'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(native, ['Utils.EnterNativeFullscreen']);
    expect(MacChrome.covered.value, isTrue, reason: 'the Mac\'s title strip goes, as for a played video');
    expect(at(), Offset.zero & SpaceHarness.computer, reason: 'alone over the whole window, the list under it');
    expect(find.text('The list').hitTestable(), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(native, ['Utils.EnterNativeFullscreen', 'Utils.ExitNativeFullscreen']);
    expect(MacChrome.covered.value, isFalse);
    expect(at().left, 320);
    expect(find.text('The list').hitTestable(), findsOneWidget);
    // The button both ways.
    await tester.tap(find.bySemanticsLabel('Full screen'));
    await tester.pump();
    expect(at().left, 0);
    await tester.tap(find.bySemanticsLabel('Leave full screen'));
    await tester.pump();
    expect(at().left, 320);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
  });

  testWidgets('no full screen until the picture is here; the pin button pins and says when it is pinned', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();
    var pins = 0;
    await h.shoot(tester, ScreenStage(name: 'Sam Ortiz', stream: null, screen: false, onPin: () => pins++, onBack: () {}), 'call-stage-waiting');
    expect(find.text('Waiting for Sam Ortiz\'s video…'), findsOneWidget);
    expect(find.text('Sam Ortiz'), findsOneWidget, reason: 'a camera is named as the person is');
    expect(find.bySemanticsLabel('Full screen'), findsNothing);
    await tester.tap(find.bySemanticsLabel('Pin'));
    expect(pins, 1);
    await h.shoot(tester, ScreenStage(name: 'Sam Ortiz', stream: null, screen: false, pinned: true, onPin: () => pins++, onBack: () {}), 'call-stage-pinned');
    expect(find.bySemanticsLabel('Unpin'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
  });

  test('what is shown large: the one pinned, else the screen someone shares unless it was put away', () {
    final s = _call();
    expect(stagedIn(s), (id: 'a', name: 'Maya Chen', stream: null, screen: true, pinned: false, mirror: false));
    expect(stagedIn(s, putAway: 'a'), isNull);
    expect(CallPin.canPin(s, 'b'), isTrue);
    expect(CallPin.canPin(s, 'c'), isFalse, reason: 'no camera and no screen: nothing to keep large');
    CallPin.toggle(s, 'b');
    expect(stagedIn(s, putAway: 'a'), (id: 'b', name: 'Sam Ortiz', stream: null, screen: false, pinned: true, mirror: false));
    // Someone pinned whose camera has gone off is not shown large.
    s.members['b'] = const VoiceMember('b', name: 'Sam Ortiz');
    expect(stagedIn(s)?.id, 'a');
    // Another call's pin is not this one's.
    final other = VoiceSession(channel: VoiceChannel.make('Other'), route: _NoRoute(), media: _NoMedia(), name: 'Me')..members['b'] = const VoiceMember('b', name: 'Sam Ortiz', video: true);
    expect(CallPin.inCall(other), isNull);
    CallPin.toggle(s, 'b');
    expect(CallPin.inCall(s), isNull, reason: 'again unpins');
  });

  testWidgets('a friend\'s call: a shared screen covers the call until Back to call, View brings it back, and a pin outlasts it', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();
    final s = _call();
    await h.shoot(tester, StagedCall(session: s, child: const Center(child: Text('The call'))), 'call-stage-friend');
    expect(find.text('Maya Chen\'s screen'), findsOneWidget);
    expect(find.text('The call').hitTestable(), findsNothing);
    await tester.tap(find.text('Back to call'));
    await tester.pump();
    expect(find.text('Maya Chen\'s screen'), findsNothing);
    expect(find.text('The call').hitTestable(), findsOneWidget);
    expect(find.text('Maya Chen is sharing their screen'), findsOneWidget);
    await tester.tap(find.text('View'));
    await tester.pump();
    expect(find.text('Maya Chen\'s screen'), findsOneWidget);
    // Sam pinned: his camera is the one large, over Maya's screen, until unpinned.
    CallPin.toggle(s, 'b');
    await tester.pump();
    expect(find.text('Maya Chen\'s screen'), findsNothing);
    expect(find.text('Sam Ortiz'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Unpin'));
    await tester.pump();
    expect(CallPin.inCall(s), isNull);
    expect(find.text('Maya Chen\'s screen'), findsOneWidget);
    // Pinned from the stage itself, a shared screen stays through Back to call's line.
    await tester.tap(find.bySemanticsLabel('Pin'));
    await tester.pump();
    expect(CallPin.inCall(s), 'a');
    await tester.tap(find.text('Back to call'));
    await tester.pump();
    expect(CallPin.inCall(s), isNull, reason: 'Back to call lets the pin go');
    expect(find.text('The call').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
  });

  testWidgets('what a press on someone opens has Pin while their picture is on, and Unpin once pinned', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    final s = _call();
    late BuildContext page;
    await h.shoot(tester, Builder(builder: (context) {
      page = context;
      return const SizedBox.expand();
    }), 'call-stage-sheet');
    showPerson(page, s, 'c', 'Riley');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('sheet-pin')), findsNothing, reason: 'no picture to pin');
    Navigator.of(page, rootNavigator: true).pop();
    await tester.pump(const Duration(milliseconds: 400));
    showPerson(page, s, 'b', 'Sam Ortiz');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Pin'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sheet-pin')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(CallPin.inCall(s), 'b');
    expect(find.byKey(const ValueKey('sheet-pin')), findsNothing, reason: 'the sheet closes on the choice');
    showPerson(page, s, 'b', 'Sam Ortiz');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Unpin'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sheet-pin')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(CallPin.inCall(s), isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  // GMFB-29: "A stage/stream mode: some people speak, many listen, with a listener count". Only whoever managed the
  // space was told the count, in a row of the call's menu.
  testWidgets('a stage says how many are listening under the space\'s name, and hands raised to whoever manages it', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    final base = h.call(people: 3, withChat: false);
    SpaceCall stage({int? listening, int hands = 0}) => SpaceCall(channel: base.channel, people: base.people, levels: base.levels, changes: base.changes, listening: listening, hands: hands);
    await h.shoot(tester, TelegramCall(call: stage()), 'space-telegram-not-stage');
    expect(find.text('4 in voice'), findsOneWidget);
    expect(find.byKey(const ValueKey('tg-stage-line')), findsNothing);
    await h.shoot(tester, TelegramCall(call: stage(listening: 2)), 'space-telegram-stage');
    expect(find.text('Stage · 2 listening'), findsOneWidget);
    expect(find.text('4 in voice'), findsNothing);
    await h.shoot(tester, TelegramCall(call: stage(listening: 3, hands: 1)), 'space-telegram-stage-hands');
    expect(find.text('Stage · 3 listening · 1 hand raised'), findsOneWidget);
    expect(SpaceCall.stageLine(12, hands: 2), 'Stage · 12 listening · 2 hands raised');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  });
}
