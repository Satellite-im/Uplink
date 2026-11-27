import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/net/crypto.dart' show NetKeys, NetCrypto;
import 'package:ghost_messaging/net/hub_carrier.dart' show KeysSigner, RoomEvent;
import 'package:ghost_messaging/ui/circles/new_circle.dart' show circleHueInk;
import 'package:ghost_messaging/ui/common.dart' show GhostPage;
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart';
import 'package:glacier/glacier.dart';

import 'support/space_call_harness.dart';

/// Names in a circle's space take the colour of their highest coloured role in the circle (Matt, 2026-11-19: "users
/// names are not updating in chat to reflect their role status"): the chat had coloured them by the space's own
/// roles, so a role given in the circle never showed there.
class _Route implements VoiceRoute {
  _Route(this.me);
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

const _maya = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1';
const _theo = 'b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2';
const _sam = 'c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3';

Color? _inkOf(WidgetTester tester, String name) {
  final text = tester.widget<Text>(find.text(name).first);
  return text.style?.color;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null));
  tearDown(() async {
    Circles.instance.signerOverride = null;
    await Circles.instance.clear();
  });

  testWidgets('a name in a circle\'s chat is its highest coloured circle role\'s, and changes when a role is given', (tester) async {
    final h = await SpaceHarness.load(tester);
    final me = NetKeys.generate(), owner = NetKeys.generate();
    Circles.instance.signerOverride = KeysSigner(me);
    final leads = CircleRole.make('Leads', hue: 'rose');
    final readers = CircleRole.make('Readers', hue: 'amber');
    final general = CircleSpace(seed: '7b' * 32, name: 'General', kind: SpaceKind.text);
    final base = CircleManifest(owner: NetCrypto.hex(owner.public), version: 1, name: 'Book club', spaces: [general]);
    final first = base.next(extra: base.withRoles(roles: [leads, readers], assignments: {_maya: [leads.id, readers.id], _theo: [readers.id]}));
    final c = Circle(seed: '7' * 64, owner: NetCrypto.hex(owner.public), manifest: first);
    Circles.instance.join(c);
    final channel = Circles.instance.bySeed(c.seed)!.channelOf(general);
    final at = DateTime(2026, 11, 19, 9).millisecondsSinceEpoch;
    final store = MemoryHangoutStore()
      ..keepRoster(channel.chatRoom, Roster.first(channel.owner))
      ..keepMessages(channel.chatRoom, [
        HangoutMessage(id: '1', from: _maya, name: 'Maya Chen', text: 'Welcome all', at: at),
        HangoutMessage(id: '2', from: _theo, name: 'Theo Park', text: 'Thanks!', at: at + 60000),
        HangoutMessage(id: '3', from: _sam, name: 'Sam Rivera', text: 'Hi', at: at + 120000),
      ]);
    final room = HangoutRoom(channel: channel, route: _Route(me.id), name: 'Me', signer: KeysSigner(me), store: store);
    await room.open();
    await h.shoot(tester, GhostPage(title: '# general', body: HangoutChat(room: room)), 'space-role-names');
    final t = tester.element(find.byType(HangoutChat)).tokens;
    expect(_inkOf(tester, 'Maya Chen'), circleHueInk(t, 'rose'), reason: 'her highest coloured role, Leads');
    expect(_inkOf(tester, 'Theo Park'), circleHueInk(t, 'amber'));
    expect(_inkOf(tester, 'Sam Rivera'), isNot(circleHueInk(t, 'amber')), reason: 'no role, no colour');

    // Sam is made a Lead in the circle: his name changes, without the chat being opened again.
    final now = Circles.instance.bySeed(c.seed)!;
    final next = now.manifest.next(extra: now.manifest.withRoles(roles: [leads, readers], assignments: {_maya: [leads.id, readers.id], _theo: [readers.id], _sam: [leads.id]}));
    Circles.instance.putForTest(Circle(seed: c.seed, owner: c.owner, manifest: next));
    await tester.pump();
    expect(_inkOf(tester, 'Sam Rivera'), circleHueInk(t, 'rose'));
    await tester.pump(const Duration(seconds: 1));
  });
}
