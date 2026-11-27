import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/net/crypto.dart' show NetKeys, NetCrypto;
import 'package:ghost_messaging/net/hub_carrier.dart' show KeysSigner, RoomEvent;
import 'package:ghost_messaging/ui/common.dart' show GhostPage;
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/ui/special_badges.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/space_call_harness.dart';

/// One badge beside a name, the one its holder chose (Matt, 2026-11-20: "allow the user to choose one badge to showcase
/// next to their names don't show them all, also the badges sit a little too high").
const _maya = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

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

HangoutRoom _room({required bool circle}) {
  final keys = NetKeys.generate(), owner = NetKeys.generate();
  final channel = VoiceChannel(seed: NetCrypto.hex(NetCrypto.randomBytes(32)), name: 'general', owner: NetCrypto.hex(owner.public), kind: SpaceKind.text, circle: circle ? 'c' * 64 : null);
  final store = MemoryHangoutStore()
    ..keepRoster(channel.chatRoom, Roster.first(channel.owner))
    ..keepMessages(channel.chatRoom, [HangoutMessage(id: '1', from: _maya, name: 'Maya Chen', text: 'Found another one', at: DateTime(2026, 11, 20, 9).millisecondsSinceEpoch)]);
  return HangoutRoom(channel: channel, route: _Route(keys.id), name: 'Me', signer: KeysSigner(keys), store: store);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null);
    SpecialBadges.instance.reset();
  });

  test('the one shown: the chosen of one\'s own, else the highest', () {
    final b = SpecialBadges()..heard(ids: ['x', 'y'], names: const [], byId: {'x': ['alpha', 'bughunter'], 'y': ['alpha', 'bughunter']}, showById: {'y': 'alpha'});
    expect(b.shownOf('x')!.id, 'bughunter', reason: 'none chosen: the highest');
    expect(b.shownOf('y')!.id, 'alpha');
    expect(b.shownOf('z'), isNull);
  });

  test('your own: the one the relay says you chose', () {
    final me = Me.forTest();
    me.hear({'dir': 'souls', 'n': 5, 'special': ['alpha', 'bughunter'], 'show': 'alpha'});
    expect(me.showcase, 'alpha');
  });

  for (final circle in [true, false]) {
    testWidgets('beside a name, one badge of her two, level with the name (${circle ? 'a channel' : 'bubbles'})', (tester) async {
      final h = await SpaceHarness.load(tester);
      SpecialBadges.instance.heard(ids: [_maya], names: const [], byId: {_maya: ['alpha', 'bughunter']}, showById: {_maya: 'alpha'});
      final room = _room(circle: circle);
      await room.open();
      await h.shoot(tester, GhostPage(title: '# general', body: HangoutChat(room: room)), 'badge-showcase-${circle ? 'channel' : 'bubbles'}');
      expect(find.byKey(const ValueKey('special-alpha-$_maya')), findsOneWidget);
      expect(find.byKey(const ValueKey('special-bughunter-$_maya')), findsNothing, reason: 'one, not all');
      // Its middle level with the name's letters' middle (their x-height), not above it.
      final name = tester.getRect(find.text('Maya Chen'));
      final mark = tester.getRect(find.byKey(const ValueKey('special-alpha-$_maya')));
      final letters = name.top + name.height * 0.55;
      expect((mark.center.dy - letters).abs(), lessThanOrEqualTo(name.height * 0.12), reason: 'mark ${mark.center.dy}, name ${name.top}..${name.bottom}');
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
