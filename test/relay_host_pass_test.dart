import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/net/p2p/node.dart';
import 'package:ghost_messaging/relay_host/direct_link.dart';

import 'support/direct_world.dart';
import 'support/fake_p2p.dart';
import 'support/host_support.dart';

/// A relay hosted from the app with a pass phrase, guessed at over Direct by strangers who make a new node for each
/// handful of guesses (node ids cost nothing). From the review's probe (2026-11-23): with a count for everyone of 200
/// wrong an hour, ten made-up nodes shut everyone out of the relay, the host's own app in memory too, again each hour.
/// Now each node pays for its own (a few free, then it waits), strangers together are held to 200 an hour, and the
/// host's own app is never asked.

const phrase = 'the long way round the lake';
const helper = 'https://link.example';

/// One guess from [node] at the relay on [hostNode], over channel 1: what the hub answered (`pass`).
Future<String?> _guess(FakeP2pNode node, String hostNode, NetKeys keys) async {
  final s = await node.open(hostNode, P2pChannel.hub, hint: const Whereabouts(helper: helper));
  final said = <Map>[];
  final done = Completer<void>();
  s.frames.listen((f) {
    final m = DirectFrames.decode(f);
    if (m is String) said.add(jsonDecode(m) as Map);
  }, onDone: () => done.isCompleted ? null : done.complete());
  await waitFor(() => said.isNotEmpty, 'the hub never said hello');
  final nonce = NetCrypto.unhex(said.first['hello'] as String);
  final sig = NetCrypto.sign(keys, [...utf8.encode(HubCarrier.greeting), ...nonce]);
  // A guess's proof (here simply not the phrase's): 32 bytes, in hex.
  final proof = NetCrypto.hex(NetCrypto.randomBytes(32));
  await s.add(DirectFrames.encode(jsonEncode({'id': keys.id, 'key': base64Encode(keys.public), 'sig': base64Encode(sig), 'pass': proof})));
  await waitFor(() => said.length > 1, 'the hub never answered the guess');
  await done.future.timeout(const Duration(seconds: 5), onTimeout: () {});
  return said[1]['pass'] as String?;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);
  late World w;
  setUp(() => w = World(helpers: const [helper]));
  tearDown(() => w.stop());

  test('strangers over Direct, a new node for every few guesses, spend strangers\' guesses but never shut out the host\'s own app', () async {
    final hostDevice = w.install(w.account('hana'), computer: true);
    await hostDevice.start();
    final host = makeHost(Kept(), timer: w.clock.timer, p2p: () => hostDevice.p2p);
    addTearDown(host.shutdown);
    await host.setOn(true);
    await host.setPass(phrase);
    await w.until(() => host.directUrl != null, 'the relay never had an address over Direct');
    final hostNode = hostDevice.p2p.nodeId!;

    // Forty-one made-up nodes, six guesses each: each node's first five are looked at, its sixth waits; past 200
    // wrong in all, a stranger's aren't looked at for the hour.
    var wrong = 0, busy = 0;
    for (var i = 0; i < 41; i++) {
      final node = w.mesh.node(network: 'far-$i');
      await node.start(P2pConfig(secret: NetCrypto.randomBytes(32), helpers: const [helper]));
      final keys = NetKeys.generate();
      for (var g = 0; g < 6; g++) {
        final answer = await _guess(node, hostNode, keys);
        if (answer == 'wrong') wrong++;
        if (answer == 'busy') busy++;
      }
    }
    expect([wrong, busy], [200, 46], reason: 'five a node until strangers had their 200');

    // The host's own app signs in again (a restart, a network change: anything that drops it): it is let in.
    final mine = OnHost(host, pass: () => host.ownPass);
    await mine.carrier.start();
    await waitFor(() => mine.carrier.passRefused != null || mine.carrier.state.value == CarrierState.up, 'the host\'s app never got an answer');
    expect(mine.carrier.passRefused, isNull, reason: 'the app that runs the relay is never refused it');
    expect(mine.carrier.state.value, CarrierState.up);
    await mine.carrier.stop();
  }, timeout: const Timeout(Duration(minutes: 4)));
}
