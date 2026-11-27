import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/crypto.dart' show NetKeys, NetCrypto;
import 'package:ghost_messaging/net/hub_carrier.dart' show RoomEvent, KeysSigner;
import 'package:ghost_messaging/ui/common.dart' show GhostPage;
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/me/verified_numbers.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/space_call_harness.dart';

/// The verified-number badge (Matt, 2026-11-19: "add the verfied by number badge as a default feature"): asked of the
/// relay in batches, kept a while, and drawn by the names of those who verified a number.
const _maya = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _kevin = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

class _Route implements VoiceRoute {
  _Route(this.me, this.key);
  @override
  final String me;
  final List<int> key;

  /// What was said in the room, opened.
  final said = <Map<String, dynamic>>[];
  @override
  Future<List<String>> join(String room, String token) async => const [];
  @override
  void leave(String room) {}
  @override
  void send(String room, Uint8List bytes) {
    final clear = NetCrypto.open(key, bytes);
    if (clear != null) said.add((jsonDecode(utf8.decode(clear)) as Map).cast<String, dynamic>());
  }

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

({HangoutRoom room, _Route route}) _room({bool circle = true, List<HangoutMessage> Function(String me)? messages}) {
  final keys = NetKeys.generate(), owner = NetKeys.generate();
  final channel = VoiceChannel(seed: NetCrypto.hex(NetCrypto.randomBytes(32)), name: 'general', owner: NetCrypto.hex(owner.public), kind: SpaceKind.text, circle: circle ? 'c' * 64 : null);
  final store = MemoryHangoutStore();
  store.keepRoster(channel.chatRoom, Roster.first(channel.owner));
  final at = DateTime(2026, 11, 19, 9).millisecondsSinceEpoch;
  store.keepMessages(channel.chatRoom, messages?.call(keys.id) ??
      [
        HangoutMessage(id: '1', from: _maya, name: 'Maya Chen', text: 'Morning all!', at: at),
        HangoutMessage(id: '2', from: _kevin, name: 'Kevin Moss', text: 'Coffee first.', at: at + 60000),
      ]);
  final route = _Route(keys.id, channel.key);
  return (room: HangoutRoom(channel: channel, route: route, name: 'Me', signer: KeysSigner(keys), store: store), route: route);
}

void main() {
  test('asked of the relay once for all the faces drawn together; yes by id or by username; kept; held off after a failure', () async {
    final asked = <(List<String>, List<String>)>[];
    var fail = false;
    final n = VerifiedNumbers(ask: (ids, names) async {
      asked.add((ids, names));
      if (fail) throw StateError('relay out of reach');
      return (ids: {_maya}, names: {'kev'});
    });
    expect(n.of(_maya), isNull, reason: 'not known yet: asked');
    expect(n.of(_kevin, username: 'Kev'), isNull);
    expect(n.of('cccccccccccccccccccccccccccccccc'), isNull);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(asked, hasLength(1), reason: 'one question for all three');
    expect(asked.single.$1, [_maya, _kevin, 'cccccccccccccccccccccccccccccccc']);
    expect(asked.single.$2, ['kev']);
    expect(n.of(_maya), isTrue);
    expect(n.of(_kevin, username: 'kev'), isTrue, reason: 'by username: a paired computer carries its phone\'s badge');
    expect(n.of('cccccccccccccccccccccccccccccccc'), isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(asked, hasLength(1), reason: 'kept, not asked again');

    final other = VerifiedNumbers(ask: (ids, names) async {
      asked.add((ids, names));
      throw StateError('relay out of reach');
    });
    expect(other.of('dddddddddddddddddddddddddddddddd'), isNull);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(asked, hasLength(2));
    expect(other.of('dddddddddddddddddddddddddddddddd'), isNull);
    await Future<void>.delayed(Duration.zero);
    expect(asked, hasLength(2), reason: 'held off a while after the relay didn\'t answer');
    fail = true;
  });

  testWidgets('the badge is by the names of those the relay says verified a number, and not by others', (tester) async {
    final was = VerifiedNumbers.instance;
    VerifiedNumbers.instance = VerifiedNumbers(ask: (ids, names) async => (ids: {_maya}, names: <String>{}));
    addTearDown(() => VerifiedNumbers.instance = was);
    final h = await SpaceHarness.load(tester);
    final (:room, route: _) = _room();
    await room.open();
    await h.shoot(tester, GhostPage(title: '# general', body: HangoutChat(room: room)), 'space-verified');
    await tester.pump();
    expect(find.byKey(const ValueKey('verified-$_maya')), findsWidgets);
    expect(find.byKey(const ValueKey('verified-$_kevin')), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });
}
