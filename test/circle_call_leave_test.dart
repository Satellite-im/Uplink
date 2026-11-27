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
import 'package:ghost_messaging/ui/space_designs/space_design.dart';
import 'package:ghost_messaging/ui/voice_screen.dart' show CallBanner;
import 'package:ghost_messaging/voice/channels.dart' show Voice;
import 'package:ghost_messaging/voice/voice.dart';

import 'support/list_harness.dart';

/// Leaving a circle's call, or putting it away, lands back on the circle (Matt, 2026-11-17: "leaving a space call takes
/// us out of the circle completely it should take us back to the circle not the whole main screen"). The call's page
/// in a wide window is pushed over everything, and it closed itself on every change to the call after the call ended:
/// while it was already leaving, each of those closes reached the shell's own back, which put away the circle's space
/// and then the circle.
Future<void> _fonts() async {
  final loader = FontLoader('Inter Variable')..addFont(File('assets/fonts/InterVariable-latin.ttf').readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
  await loader.load();
}

final _circle = Circle(
  seed: '8' * 64,
  owner: '',
  manifest: CircleManifest(owner: '', version: 1, name: 'Night Owls', hue: 'indigo', icon: 'sparkles', spaces: [
    CircleSpace(seed: '8b' * 32, name: 'Lounge'),
    CircleSpace(seed: '8a' * 32, name: 'General', kind: SpaceKind.text, order: 1),
  ]),
);

/// In [c]'s call as Voice.join leaves it, without a relay or WebRTC: the session, and everyone told.
void _join(VoiceChannel c) {
  final v = Voice.instance;
  v.session = VoiceSession(channel: c, route: _NoRoute(), media: _NoMedia(), name: 'Me')..members['a'] = const VoiceMember('a', name: 'Maya Chen');
  // Tells Voice's listeners, as join does once the session is set.
  v.putLook(c.room, const ['a']);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_fonts);
  setUp(() {
    ListPhone(const []).install();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost/voicefx'), (call) async => null);
  });
  tearDown(() async {
    Voice.instance.session = null;
    Voice.instance.putLook(_circle.channels.first.room, const []);
    await Circles.instance.clear();
  });

  for (final (name, size, wide) in [('a phone', const Size(412, 892), false), ('a wide window', const Size(1100, 832), true)]) {
    // Beside the list the call is the top of the space's own page (SpaceSplit), with nothing to put away: Leave alone.
    for (final how in [if (!wide) 'Back', 'Leave']) {
      testWidgets('on $name, ${how == 'Leave' ? 'leaving' : 'putting away'} a circle\'s call lands back on the circle', (tester) async {
        Circles.instance.join(_circle);
        final sheet = await loadSheet(tester);
        await pumpScreen(tester, sheet, const AppShell(), AppState(), size: size);
        final shell = AppShellState.live!;
        shell.openCircle(_circle);
        await settle(tester);
        final lounge = _circle.channels.firstWhere((c) => c.name == 'Lounge');
        // Its voice space, opened from the circle's list (beside it, the first space is open already).
        if (!wide) {
          await tester.tap(find.text('Lounge').last);
          await settle(tester);
        }
        expect(find.byType(HangoutScreen), findsOneWidget);

        // Joined: on a phone the space's page is the call (the Telegram design, the default); beside the list the call
        // is the top of the space's page, the chat under it, nothing pushed over the window (Matt, 2026-11-23).
        _join(lounge);
        await settle(tester);
        if (wide) {
          expect(openSpaceCall(tester.element(find.byType(HangoutScreen))), isFalse);
          await settle(tester);
          expect(find.byType(SpaceSplit), findsOneWidget);
        }
        expect(find.byType(SpaceCallPage), findsOneWidget);

        await tester.tap(find.bySemanticsLabel(how).last);
        await tester.pump(const Duration(milliseconds: 50));
        // While the call's page is still on its way out, the relay says who is left in the room (Voice tells its
        // listeners on every such word, and on the room's own as it is let go).
        Voice.instance.putLook(lounge.room, const []);
        await tester.pump(const Duration(milliseconds: 50));
        Voice.instance.putLook(lounge.room, const ['a']);
        await settle(tester);
        await tester.pump(const Duration(seconds: 1));

        expect(find.byType(SpaceCallPage), findsNothing, reason: 'the call\'s page is gone');
        expect(shell.circleOpen, isTrue, reason: 'the circle is still in the list\'s place');
        expect(find.byType(CircleScreen, skipOffstage: false), findsOneWidget);
        if (wide || how == 'Leave') {
          // Beside the list the space stays in the pane; on a phone, left from inside the space, its chat is the page.
          expect(find.byType(HangoutScreen), findsOneWidget, reason: 'the space is still open');
          expect(AppShell.showingOf(tester.element(find.byType(HangoutScreen))), 'circle');
        } else {
          // Put away on a phone: the call's back is the space's, back to the circle's list.
          expect(find.byType(HangoutScreen), findsNothing);
        }
        expect(tester.takeException(), isNull);
        Voice.instance.session = null;
      });
    }
  }

  // The call put away on a phone, then opened again from its banner over the circle's list: the shell opens it as a
  // page over everything (openSpaceCall is asked from the shell's own context), as a wide window does, so it too must
  // close once and leave the circle where it is.
  for (final how in ['Leave', 'Back']) {
    testWidgets('on a phone, a circle\'s call opened from its banner and ${how == 'Leave' ? 'left' : 'put away'} lands on the circle', (tester) async {
      Circles.instance.join(_circle);
      final sheet = await loadSheet(tester);
      await pumpScreen(tester, sheet, const AppShell(), AppState());
      final shell = AppShellState.live!;
      shell.openCircle(_circle);
      await settle(tester);
      final lounge = _circle.channels.firstWhere((c) => c.name == 'Lounge');
      _join(lounge);
      await settle(tester);
      await tester.tap(find.byType(CallBanner));
      await settle(tester);
      expect(find.byType(SpaceCallPage), findsOneWidget);
      await tester.tap(find.bySemanticsLabel(how).last);
      await tester.pump(const Duration(milliseconds: 50));
      Voice.instance.putLook(lounge.room, const []);
      await tester.pump(const Duration(milliseconds: 50));
      Voice.instance.putLook(lounge.room, const ['a']);
      await settle(tester);
      expect(find.byType(SpaceCallPage), findsNothing);
      expect(shell.circleOpen, isTrue, reason: 'the circle is still in the list\'s place');
      expect(find.byType(CircleScreen), findsOneWidget, reason: 'its list is the screen');
      expect(tester.takeException(), isNull);
      Voice.instance.session = null;
    });
  }
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
