import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/net/hub_carrier.dart' show RoomEvent;
import 'package:ghost_messaging/ui/circles/circle_screen.dart';
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/ui/shell.dart';
import 'package:ghost_messaging/voice/channels.dart' show Voice;
import 'package:ghost_messaging/voice/voice.dart';

import 'support/list_harness.dart';

/// A voice space pressed in a circle's list beside the pane comes into its call at once (GMFB-72: "Instead of having
/// to click join voice, join a voice chat when clicking on a space in the sidebar"); on a phone, and for every space
/// that is not a plain voice space, a press opens it as before. And what someone shows a call, their camera or their
/// screen, as the call says it (GMFB-66).
Future<void> _fonts() async {
  final loader = FontLoader('Inter Variable')..addFont(File('assets/fonts/InterVariable-latin.ttf').readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
  await loader.load();
}

final _circle = Circle(
  seed: '7' * 64,
  owner: '',
  manifest: CircleManifest(owner: '', version: 1, name: 'Night Owls', hue: 'indigo', icon: 'sparkles', spaces: [
    CircleSpace(seed: '7a' * 32, name: 'General', kind: SpaceKind.text),
    CircleSpace(seed: '7b' * 32, name: 'Lounge', order: 1),
    CircleSpace(seed: '7c' * 32, name: 'Floor', kind: SpaceKind.open, order: 2),
    CircleSpace(seed: '7d' * 32, name: 'Texts', order: 3, extra: const {'sms': {'by': 'someone'}}),
    CircleSpace(seed: '7e' * 32, name: 'Den', order: 4),
  ]),
);

VoiceChannel _space(String name) => _circle.channels.firstWhere((c) => c.name == name);

/// In [c]'s call as Voice.join leaves it, without a relay or WebRTC.
VoiceSession _join(VoiceChannel c) {
  final v = Voice.instance;
  final s = v.session = VoiceSession(channel: c, route: _NoRoute(), media: _NoMedia(), name: 'Me')..members['a'] = const VoiceMember('a', name: 'Maya Chen');
  v.putLook(c.room, const ['a']);
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_fonts);
  late List<String> joined;
  setUp(() {
    ListPhone(const []).install();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost/voicefx'), (call) async => null);
    joined = [];
    joinPressedSpace = (c) async => joined.add(c.name);
  });
  tearDown(() async {
    resetJoinPressedSpace();
    Voice.instance.session = null;
    for (final c in _circle.channels) {
      Voice.instance.putLook(c.room, const []);
    }
    await Circles.instance.clear();
  });

  Future<void> press(WidgetTester tester, String name) async {
    await tester.tap(find.byKey(ValueKey('circle-space-${_space(name).seed}')));
    await settle(tester);
  }

  testWidgets('beside the pane, a press on a voice space comes into its call; any other space just opens', (tester) async {
    Circles.instance.join(_circle);
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const AppShell(), AppState(), size: const Size(1100, 832));
    AppShellState.live!.openCircle(_circle);
    await settle(tester);
    expect(joined, isEmpty, reason: 'the space a circle opens on is not pressed');

    await press(tester, 'Lounge');
    expect(joined, ['Lounge']);
    expect(openCircleSpaceSeed.value, _space('Lounge').seed, reason: 'and it is the space shown');
    expect(find.byType(HangoutScreen), findsOneWidget);

    // A texting space, an open space (its floor has its own way in) and an SMS space open and no more.
    for (final other in ['General', 'Floor', 'Texts']) {
      await press(tester, other);
      expect(openCircleSpaceSeed.value, _space(other).seed);
    }
    expect(joined, ['Lounge']);

    // In its call already: shown, not come into again. Another voice space is hopped to, as Join voice does.
    _join(_space('Lounge'));
    await settle(tester);
    await press(tester, 'Lounge');
    expect(joined, ['Lounge']);
    expect(find.byType(SpaceSplit), findsOneWidget, reason: 'its call is what the pane shows');
    await press(tester, 'Den');
    expect(joined, ['Lounge', 'Den']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('on a phone a press on a voice space opens it, with Join voice in its page as before', (tester) async {
    Circles.instance.join(_circle);
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const AppShell(), AppState(), size: const Size(412, 892));
    AppShellState.live!.openCircle(_circle);
    await settle(tester);
    await press(tester, 'Lounge');
    expect(find.byType(HangoutScreen), findsOneWidget);
    expect(joined, isEmpty);
    expect(tester.takeException(), isNull);
  });

  test('what someone shows a call is their camera or their screen, as the call says', () {
    final lounge = _space('Lounge');
    final v = Voice.instance;
    expect(v.pictureOf(lounge, 'a'), (camera: false, screen: false), reason: 'out of the call, and nobody said');
    final s = _join(lounge);
    s.members['a'] = const VoiceMember('a', name: 'Maya Chen', video: true);
    // A shared screen is said with video too, so an older build shows it: it is a screen, not a camera.
    s.members['b'] = const VoiceMember('b', name: 'Sam', video: true, screen: true);
    s.members['c'] = const VoiceMember('c', name: 'Kai');
    expect(v.pictureOf(lounge, 'a'), (camera: true, screen: false));
    expect(v.pictureOf(lounge, 'b'), (camera: false, screen: true));
    expect(v.pictureOf(lounge, 'c'), (camera: false, screen: false));
    expect(v.pictureOf(lounge, 'me'), (camera: false, screen: false));
    s.video = true;
    expect(v.pictureOf(lounge, 'me'), (camera: true, screen: false));
    s.screen = true;
    expect(v.pictureOf(lounge, 'me'), (camera: false, screen: true));
    expect(v.pictureOf(_space('Den'), 'a'), (camera: false, screen: false), reason: 'another space\'s call');
  });
}

/// A relay that is never reached.
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
