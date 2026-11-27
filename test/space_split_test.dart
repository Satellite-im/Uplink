import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/net/crypto.dart' show NetKeys;
import 'package:ghost_messaging/net/hub_carrier.dart' show RoomEvent, KeysSigner;
import 'package:ghost_messaging/ui/circles/circle_screen.dart';
import 'package:ghost_messaging/ui/composer_box.dart';
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/ui/shell.dart';
import 'package:ghost_messaging/ui/space_designs/space_design.dart';
import 'package:ghost_messaging/ui/voice_screen.dart' show CallBanner, CallDock;
import 'package:ghost_messaging/voice/channels.dart' show Voice;
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/list_harness.dart';

/// A voice space's call on a computer is the space's own page in the pane, beside the circle's list: the call on top,
/// two thirds of the pane, and the space's chat with its composer under it (Matt, 2026-11-23, Mac 0.12.23: "when first
/// joining a space we see this weird ui then clicking on the space shows the second screenshot, instead to a 66% top
/// view with the third screenshot content at the top and the chat and compose bar at the bottom leaving the sidebar
/// unchanged so you can still quickly navigate the circle"). Joining showed a sparse list of who is in it with the
/// call's buttons floating at its foot, and opening the space pushed the call over the whole window, the circle's list
/// under it. Run with --update-goldens and SPLIT_SHOTS=before or after, the pictures are build/space-split/<that>/*.png.
Future<void> _fonts() async {
  final loader = FontLoader('Inter Variable')..addFont(File('assets/fonts/InterVariable-latin.ttf').readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
  await loader.load();
}

final _circle = Circle(
  seed: '7' * 64,
  owner: '',
  manifest: CircleManifest(owner: '', version: 1, name: 'OnlyGhosts', hue: 'indigo', icon: 'sparkles', spaces: [
    CircleSpace(seed: '7b' * 32, name: 'Lounge'),
    CircleSpace(seed: '7a' * 32, name: 'General', kind: SpaceKind.text, order: 1),
  ]),
);

VoiceChannel get _lounge => _circle.channels.firstWhere((c) => c.name == 'Lounge');

/// The Lounge's chat, with a few messages in it, held as Voice holds a space's room.
void _room() {
  final keys = NetKeys.generate();
  final store = MemoryHangoutStore();
  final at = DateTime(2026, 11, 23, 15, 31).millisecondsSinceEpoch;
  store.keepMessages(_lounge.chatRoom, [
    HangoutMessage(id: '1', from: 'j', name: 'Jerbo', text: 'why are you yellow', at: at),
    HangoutMessage(id: '2', from: 'a', name: 'Maya Chen', text: 'hop in, we\'re picking a movie', at: at + 60000),
    HangoutMessage(id: '3', from: keys.id, name: 'Me', text: 'on my way', at: at + 120000),
  ]);
  Voice.instance.putHangout(HangoutRoom(channel: _lounge, route: _NoRoute(keys.id), name: 'Me', signer: KeysSigner(keys), store: store));
}

/// In [c]'s call as Voice.join leaves it, without a relay or WebRTC: the session, and everyone told. [others]: who
/// else is in it; [video]: with their cameras on.
void _join(VoiceChannel c, {bool others = true, bool video = false}) {
  final v = Voice.instance;
  final s = v.session = VoiceSession(channel: c, route: _NoRoute('me-id'), media: _NoMedia(), name: 'Me');
  if (others) {
    s.members['a'] = VoiceMember('a', name: 'Maya Chen', video: video);
    s.members['b'] = VoiceMember('b', name: 'Sam', video: video);
  }
  v.putLook(c.room, others ? const ['a', 'b'] : const []);
}

/// The circle open beside its list at [size], the Lounge in the pane.
Future<AppShellState> _open(WidgetTester tester, Size size, {bool dark = false, String platform = 'desktop'}) async {
  Circles.instance.join(_circle);
  _room();
  final sheet = await loadSheet(tester);
  final app = AppState();
  if (dark) app.setTheme('dark');
  await pumpScreen(tester, sheet, const AppShell(), app, size: size, platform: platform);
  final shell = AppShellState.live!;
  shell.openCircle(_circle);
  await settle(tester);
  if (find.byType(HangoutScreen).evaluate().isEmpty || find.text('Join voice').evaluate().isEmpty) {
    await tester.tap(find.text('Lounge').last);
    await settle(tester);
  }
  return shell;
}

Future<void> _shot(String name) async {
  if (!autoUpdateGoldenFiles) return;
  final phase = Platform.environment['SPLIT_SHOTS'] ?? 'after';
  await expectLater(find.byType(WidgetsApp), matchesGoldenFile('../build/space-split/$phase/$name.png'));
}

/// The pane's rectangle: right of the list's rule.
Rect _pane(WidgetTester tester) {
  final rule = tester.getRect(find.byKey(const ValueKey('shell-rule')));
  final all = tester.getRect(find.byType(AppShell));
  return Rect.fromLTRB(rule.right, all.top, all.right, all.bottom);
}

/// What a computer shows, joined and with the space pressed again in the list, both: the circle's list as it was,
/// and in the pane the call on top (about two thirds) and the chat and composer under it.
void _expectSplit(WidgetTester tester, {required String how}) {
  expect(find.byType(CircleScreen), findsOneWidget, reason: '$how: the circle\'s list is still beside the pane');
  expect(find.text('General'), findsWidgets, reason: '$how: its other spaces still listed');
  expect(find.byType(SpaceSplit), findsOneWidget, reason: '$how: the space\'s page is the call over its chat');
  final route = ModalRoute.of(tester.element(find.byType(SpaceSplit)))!;
  expect(route.settings.name, isNot('space-call'), reason: '$how: no page pushed over the window');
  expect(find.byType(AppShell), findsOneWidget);
  final pane = _pane(tester);
  final call = tester.getRect(find.byKey(const ValueKey('space-split-call')));
  final chat = tester.getRect(find.byKey(const ValueKey('space-split-chat')));
  expect(call.left, greaterThanOrEqualTo(pane.left - 1), reason: '$how: in the pane, not over the list');
  expect(chat.top, greaterThanOrEqualTo(call.bottom - 1), reason: '$how: the call on top, the chat under it');
  final whole = chat.bottom - call.top;
  expect(call.height / whole, inInclusiveRange(0.55, 0.72), reason: '$how: the call about two thirds (${call.height} of $whole)');
  expect(chat.height, greaterThanOrEqualTo(SpaceSplit.chatLeast - 1), reason: '$how: the chat keeps its composer and a few lines');
  final composer = tester.getRect(find.byType(ComposerBox));
  expect(chat.contains(composer.center), isTrue, reason: '$how: the composer in the chat\'s part');
  expect(find.text('on my way'), findsOneWidget, reason: '$how: the chat\'s messages under the call');
  // The call's own chat panel isn't needed: the chat is there, and nothing puts it away. Where Chat stood beside Leave
  // is Share screen, on a device that can share one (Matt, 2026-11-25: "replace the who hide chat button with a share
  // screen button"); this test's device cannot, so there are four buttons.
  expect(find.bySemanticsLabel('Chat'), findsNothing, reason: '$how: no Chat button over a chat that is always there');
  expect(find.byKey(const ValueKey('tg-chat-panel')), findsNothing, reason: '$how: no chat panel beside the call');
  expect(find.byType(CallBanner), findsNothing, reason: '$how: no banner for the call on the screen');
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
    Voice.instance.session = null;
    Voice.instance.putLook(_lounge.room, const []);
    Voice.instance.clearHangouts();
    await Circles.instance.clear();
  });

  for (final size in const [Size(1280, 800), Size(1440, 900), Size(1024, 700)]) {
    final at = '${size.width.toInt()}x${size.height.toInt()}';
    testWidgets('at $at, joining a voice space and opening it both show the call over its chat beside the circle', (tester) async {
      final shell = await _open(tester, size);
      _join(_lounge);
      await settle(tester);
      expect(openSpaceCall(tester.element(find.byType(HangoutScreen))), isFalse, reason: 'nothing is pushed over the window');
      await settle(tester);
      expect(find.byType(SpaceCallPage), findsOneWidget, reason: 'the chosen design (Telegram\'s) draws the call');
      _expectSplit(tester, how: 'joined');

      // Another space, then the call's space pressed in the list again.
      await tester.tap(find.text('General').last);
      await settle(tester);
      expect(find.byType(SpaceSplit), findsNothing);
      expect(find.byType(CallBanner), findsOneWidget, reason: 'the banner, looking at another space');
      await tester.tap(find.text('Lounge').last);
      await settle(tester);
      _expectSplit(tester, how: 'pressed in the list');

      // From the banner, as well.
      await tester.tap(find.text('General').last);
      await settle(tester);
      await tester.tap(find.byType(CallBanner));
      await settle(tester);
      await settle(tester);
      _expectSplit(tester, how: 'opened from the banner');
      expect(shell.circleOpen, isTrue);

      // Left: the space's normal chat again.
      await tester.tap(find.bySemanticsLabel('Leave').last);
      await settle(tester);
      expect(Voice.instance.session, isNull);
      expect(find.byType(SpaceSplit), findsNothing);
      expect(find.text('Join voice'), findsOneWidget, reason: 'back to the space\'s chat');
      expect(find.byType(CircleScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  // The call's page draws the top part, and the chat is always under it: the button that put it away is Share
  // screen now (Matt, 2026-11-25), and a device that had the chat put away gets it back.
  testWidgets('the call over its chat, which nothing puts away, a choice kept from before included', (tester) async {
    await _open(tester, const Size(1280, 800));
    _join(_lounge);
    await settle(tester);
    expect(find.byType(SpaceSplit), findsOneWidget);
    expect(find.byType(SpaceCallPage), findsOneWidget);
    expect(find.byType(CallDock), findsNothing, reason: 'the call\'s buttons are its page\'s, once');
    expect(find.text('on my way'), findsOneWidget, reason: 'the chat is under the call');
    expect(find.bySemanticsLabel('Chat'), findsNothing);
    // Put away with the old button, on this device, before it went.
    AppState.of(tester.element(find.byType(SpaceSplit))).setFlag(SpaceSplit.chatPref, false);
    await settle(tester);
    expect(find.byKey(const ValueKey('space-split-chat')), findsOneWidget, reason: 'shown all the same');
    expect(find.text('on my way'), findsOneWidget);
    expect(find.byKey(const ValueKey('space-split-handle')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the line between the call and the chat is dragged, kept, and held clear of the composer', (tester) async {
    await _open(tester, const Size(1280, 800));
    _join(_lounge);
    await settle(tester);
    final before = tester.getRect(find.byKey(const ValueKey('space-split-call'))).height;
    await tester.drag(find.byKey(const ValueKey('space-split-handle')), const Offset(0, -120));
    await settle(tester);
    final after = tester.getRect(find.byKey(const ValueKey('space-split-call'))).height;
    expect(after, closeTo(before - 120, 2));
    final app = AppState.of(tester.element(find.byType(SpaceSplit)));
    expect(double.parse(app.choice(SpaceSplit.pref, '')), closeTo(after / (after + tester.getRect(find.byKey(const ValueKey('space-split-chat'))).height + 1), 0.01));
    // Dragged far down, the chat still keeps its composer and a few lines.
    await tester.drag(find.byKey(const ValueKey('space-split-handle')), const Offset(0, 900));
    await settle(tester);
    expect(tester.getRect(find.byKey(const ValueKey('space-split-chat'))).height, greaterThanOrEqualTo(SpaceSplit.chatLeast - 1));
    expect(SpaceSplit.callHeight(300, 0.66), closeTo(100, 0.1), reason: 'a very short pane: the chat first');
    expect(tester.takeException(), isNull);
  });

  // Alone in the call, the default design in the split's top part: the waiting words are never cut by the buttons,
  // and the four buttons (no Chat) are an evenly spaced group, not three and a gap and Leave at the far right.
  for (final size in const [Size(1280, 800), Size(1024, 700), Size(1440, 900)]) {
    final at = '${size.width.toInt()}x${size.height.toInt()}';
    testWidgets('at $at alone, the waiting words clear the buttons and the buttons are evenly spaced', (tester) async {
      await _open(tester, size);
      _join(_lounge, others: false);
      await settle(tester);
      openSpaceCall(tester.element(find.byType(HangoutScreen)));
      await settle(tester);
      final call = tester.getRect(find.byKey(const ValueKey('space-split-call')));
      final buttons = [for (final b in ['Video', 'Deafen', 'Mute', 'Leave']) tester.getRect(find.bySemanticsLabel(b).last)];
      final top = buttons.map((r) => r.top).reduce((a, b) => a < b ? a : b);
      for (final b in buttons) {
        expect(call.contains(b.center), isTrue, reason: 'each button in the call\'s part');
      }
      final waiting = find.text('Waiting for others to join');
      if (size.height >= 800) expect(waiting, findsOneWidget, reason: 'room to say so at $at');
      if (waiting.evaluate().isNotEmpty) {
        final w = tester.getRect(waiting);
        expect(w.bottom, lessThanOrEqualTo(top), reason: 'the waiting words above the buttons, not under them');
        expect(w.top, greaterThanOrEqualTo(call.top), reason: 'nor above the call\'s part');
      }
      // Nothing scrolled out of sight: the list is at its top and does not scroll at all alone.
      final list = tester.state<ScrollableState>(find.descendant(of: find.byKey(const ValueKey('space-split-call')), matching: find.byType(Scrollable)).first);
      expect(list.position.maxScrollExtent, 0, reason: 'alone, the people and the waiting words fit without scrolling');
      final xs = [for (final b in buttons) b.center.dx];
      final gaps = [for (var i = 1; i < xs.length; i++) xs[i] - xs[i - 1]];
      for (final g in gaps) {
        expect(g, closeTo(gaps.first, 1), reason: 'even gaps between the buttons: $gaps');
      }
      final mid = (xs.first + xs.last) / 2;
      expect(mid, closeTo(call.center.dx, 2), reason: 'the group in the middle of the call');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('video tiles fit the top part', (tester) async {
    await _open(tester, const Size(1280, 800));
    _join(_lounge, video: true);
    await settle(tester);
    final call = tester.getRect(find.byKey(const ValueKey('space-split-call')));
    for (final id in ['a', 'b']) {
      final tile = tester.getRect(find.byKey(ValueKey('tg-tile-$id')));
      expect(call.contains(tile.center), isTrue, reason: 'each tile in the call\'s part');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('on a phone the call is still the design\'s own page, with no split', (tester) async {
    await _open(tester, const Size(412, 892), platform: 'mobile');
    _join(_lounge);
    await settle(tester);
    expect(find.byType(SpaceSplit), findsNothing);
    expect(find.byType(SpaceCallPage), findsOneWidget);
    expect(find.bySemanticsLabel('Chat'), findsWidgets, reason: 'a phone keeps its Chat button');
    expect(tester.takeException(), isNull);
  });

  // The pictures: joined, alone and with others, and with video, at a computer's size, dark.
  testWidgets('shots', (tester) async {
    for (final (name, others, video, size) in [
      ('alone', false, false, const Size(1280, 800)),
      ('joined', true, false, const Size(1280, 800)),
      ('video', true, true, const Size(1280, 800)),
      ('alone-1024x700', false, false, const Size(1024, 700)),
    ]) {
      await _open(tester, size, dark: true);
      _join(_lounge, others: others, video: video);
      await settle(tester);
      // As the pre-split build opened the space's call from its page.
      openSpaceCall(tester.element(find.byType(HangoutScreen)));
      await settle(tester);
      await _shot(name.contains('x') ? '$name-dark' : '$name-1280x800-dark');
      Voice.instance.session = null;
      Voice.instance.putLook(_lounge.room, const []);
      await tester.pumpWidget(const SizedBox.shrink());
      Voice.instance.clearHangouts();
      await Circles.instance.clear();
    }
  });
}

/// A relay that is never reached.
class _NoRoute implements VoiceRoute {
  _NoRoute(this.me);
  @override
  final String me;
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

/// No microphone, no camera.
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
