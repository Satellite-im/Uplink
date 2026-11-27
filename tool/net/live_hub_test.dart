import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_messaging/net/switchboard.dart';

/// Two installs made up here, talking through a hub that is really there (docs/network.md):
///
///     flutter test tool/net/live_hub_test.dart --dart-define=HUB=wss://gogho.st/hub
///
/// It is the check run after tool/deploy-relay.mjs. Each run makes two new key pairs, so it leaves nothing behind
/// but what it sends itself, which it also fetches: a packet held for one who is away and handed over when they
/// come, one passed while both are there, and a room joined and left.
const hub = String.fromEnvironment('HUB');

/// The peers an install knows, by id alone: all this test's switchboards ask of an address book.
class _Book implements PeerBook {
  final Map<String, Peer> all = {};
  @override
  Peer? byId(String id) => all[id];
}

/// Starts a carrier and gives it ten seconds to reach the hub; fails with the carrier's own reason if it does not.
Future<void> _up(HubCarrier c) async {
  await c.start();
  for (var i = 0; i < 400 && c.state.value != CarrierState.up; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  expect(c.state.value, CarrierState.up, reason: c.problem ?? 'it did not connect to $hub');
}

void main() {
  test('two installs through the hub at $hub', () async {
    expect(hub, isNotEmpty, reason: 'say which: --dart-define=HUB=wss://…/hub');
    final a = NetKeys.generate(), b = NetKeys.generate();
    final key = NetCrypto.netKey(NetCrypto.conversationKey(a, b.public)!);
    final hubA = HubCarrier(url: hub, signer: KeysSigner(a)), hubB = HubCarrier(url: hub, signer: KeysSigner(b));
    final left = Switchboard(me: a.id, peers: _Book()..all[b.id] = Peer(id: b.id, key: key), carriers: [hubA]);
    final right = Switchboard(me: b.id, peers: _Book()..all[a.id] = Peer(id: a.id, key: key), carriers: [hubB]);
    final got = <Received>[];
    right.received.listen(got.add);
    var began = DateTime.now();
    await _up(hubA);
    debugPrint('signed in to $hub in ${DateTime.now().difference(began).inMilliseconds} ms');

    // B is away: kept, and handed over as B comes.
    var d = await left.send(Peer(id: b.id, key: key), Envelope(kind: 'text', body: {'t': 'kept for you'}));
    expect([d.via, d.handed], ['hub', Handed.held]);
    final acked = left.acked.first;
    await _up(hubB);
    await acked.timeout(const Duration(seconds: 10));
    expect(got.single.envelope.body['t'], 'kept for you');
    debugPrint('held while away, handed over on coming, answered');

    // Both there.
    began = DateTime.now();
    d = await left.send(Peer(id: b.id, key: key), Envelope(kind: 'text', body: {'t': 'now'}));
    expect([d.handed, d.acked], [Handed.passed, true]);
    debugPrint('passed and answered in ${DateTime.now().difference(began).inMilliseconds} ms');

    // A room: named and locked by a key only its members hold.
    final roomKey = NetCrypto.randomBytes(32);
    final room = NetCrypto.hex(NetCrypto.derive(roomKey, 'room name').sublist(0, 16));
    final token = NetCrypto.hex(NetCrypto.derive(roomKey, 'room token'));
    final heard = hubA.roomPackets.first;
    expect(await hubA.join(room, token), isEmpty);
    expect(await hubB.join(room, token), [a.id]);
    hubB.sendRoom(room, Uint8List.fromList(utf8.encode('hello room')));
    expect(utf8.decode((await heard.timeout(const Duration(seconds: 10))).bytes), 'hello room');
    // A wrong token is refused. Connected first: a room asked for before the connection waits for it (HubCarrier.join).
    final stranger = HubCarrier(url: hub, signer: KeysSigner(NetKeys.generate()));
    await _up(stranger);
    await expectLater(stranger.join(room, 'f' * 64), throwsA(isA<CarrierError>()));
    await stranger.stop();
    hubA.leave(room);
    hubB.leave(room);
    debugPrint('a room joined by two, heard in, and left');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await hubA.stop();
    await hubB.stop();
  }, timeout: const Timeout(Duration(seconds: 60)));
}
