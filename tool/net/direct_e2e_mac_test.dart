import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/net/net.dart';
import 'package:ghost_messaging/net/p2p/card.dart';
import 'package:ghost_messaging/net/p2p/node.dart';
import 'package:ghost_messaging/net/p2p/node_factory.dart';
import 'package:ghost_messaging/net/p2p/p2p.dart';
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_messaging/net/switchboard.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/ui/network.dart';

/// Direct end to end, the computer's half (Matt's brief, 2026-11-23): account A on this Mac, a computer of its own, with
/// the real core (build/p2p/mac/libghost_p2p.dylib: `sh tool/build-p2p.sh mac`) under the app's own routes
/// (lib/net/net.dart); and account C, nobody's friend, which asks both A and the phone for their cards and to meet,
/// through the relay. The phone's half is integration_test/direct_e2e_test.dart (account B, on the Android emulator), and
/// how to run the two, the relay and the keys is said there:
///
///     flutter test tool/net/direct_e2e_mac_test.dart --dart-define=E2E_HUB=ws://127.0.0.1:18797/hub --dart-define=E2E_KEYS=<a>,<b>,<c>
///
/// What it sees is said in the log (`E2E …`): counts and kinds, never a key.
const _hub = String.fromEnvironment('E2E_HUB');
const _keys = String.fromEnvironment('E2E_KEYS');

void _say(String what) => debugPrint('E2E mac ${DateTime.now().toIso8601String().substring(11, 19)}: $what');

/// Waits for [ok], up to [most]; says [what] either way.
Future<bool> _until(bool Function() ok, String what, {Duration most = const Duration(minutes: 3)}) async {
  final began = DateTime.now();
  while (!ok() && DateTime.now().difference(began) < most) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  _say('${ok() ? 'saw' : 'NEVER SAW'} $what (${DateTime.now().difference(began).inSeconds} s)');
  return ok();
}

/// A computer of its own (Sms.standalone), whose calls go to the channel this test answers.
class _OwnComputer implements SmsCalls {
  static const _channel = MethodChannel('ghost_messaging/sms');
  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) => _channel.invokeMethod<T>(method, arguments);
}

class _Book implements PeerBook {
  final Map<String, Peer> all = {};
  @override
  Peer? byId(String id) => all[id];
}

/// This process's UDP sockets (lsof): the core's are its only ones.
Future<int> _udpSockets() async {
  final r = await Process.run('lsof', ['-a', '-p', '$pid', '-i', 'UDP', '-Fn']);
  return '${r.stdout}'.split('\n').where((l) => l.startsWith('n')).length;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Direct between this Mac and a phone, through our link helper, and a stranger told nothing', () async {
    expect([_hub, _keys], everyElement(isNotEmpty), reason: 'say where the relay is and the keys: --dart-define=E2E_HUB=… --dart-define=E2E_KEYS=…');
    final scalars = _keys.split(',');
    final me = NetKeys.fromScalar(NetCrypto.unhex(scalars[0])), b = NetKeys.fromScalar(NetCrypto.unhex(scalars[1])), c = NetKeys.fromScalar(NetCrypto.unhex(scalars[2]));
    Uint8List pair(NetKeys x, NetKeys y) => NetCrypto.netKey(NetCrypto.conversationKey(x, y.public)!);
    final secrets = <String, String>{};
    Sms.calls = _OwnComputer();
    Sms.standalone = true;
    expect(Sms.computer, isTrue);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
      final args = call.arguments is Map ? call.arguments as Map : const {};
      switch (call.method) {
        case 'netIdentity':
          return {'id': me.id, 'key': base64Encode(me.public)};
        case 'netSign':
          return NetCrypto.sign(me, (args['message'] as List).cast<int>());
        case 'netPeers':
          return [
            {'id': b.id, 'address': '@b', 'key': pair(me, b)},
            {'id': c.id, 'address': '@c', 'key': pair(me, c)},
          ];
        case 'buddiesKept':
          return jsonEncode([
            {'u': 'b', 'i': b.id, 'k': base64Encode(b.public), 's': 'yes'},
            {'u': 'c', 'i': c.id, 'k': base64Encode(c.public), 's': 'asked'},
          ]);
        case 'e2eList':
        case 'netSmsDrain':
          return const <Object>[];
        case 'secretKeep':
          final value = '${args['value'] ?? ''}';
          value.isEmpty ? secrets.remove('${args['name']}') : secrets['${args['name']}'] = value;
          return null;
        case 'secretRead':
          return secrets['${args['name']}'];
      }
      return null;
    });
    var made = 0;
    Net.p2pNode = () {
      made++;
      return makeP2pNode();
    };
    final got = <String>[];
    Net.instance.listen((r) {
      if (r.envelope.kind == 'text') got.add('${r.envelope.body['t']} by ${r.via}');
    });
    bool came(String words, String via) => got.contains('$words by $via');

    // C, nobody's friend: someone A and the phone hold a key with (it asked to be a friend), on the same relay.
    final cBook = _Book()
      ..all[me.id] = Peer(id: me.id, key: pair(c, me))
      ..all[b.id] = Peer(id: b.id, key: pair(c, b));
    final cHub = HubCarrier(url: _hub, signer: KeysSigner(c));
    final cBoard = Switchboard(me: c.id, peers: cBook, carriers: [cHub]);
    final cGot = <String>[];
    cBoard.received.listen((r) => cGot.add('${r.envelope.kind}${r.envelope.kind == P2p.kind ? ':${r.envelope.body['t']}' : ''} from ${r.peer.id == me.id ? 'A' : 'B'}'));
    cBoard.strangers.listen((s) => cGot.add('${s.envelope.kind} in the clear'));
    await cBoard.start();
    cHub.watch([me.id, b.id]);

    // A starts with Direct off, as everyone does: nothing of the core asked for.
    final app = AppState()..set('net_hub', _hub);
    await Net.instance.start(app);
    await _until(() => Net.instance.hub?.state.value == CarrierState.up, 'the relay signed in to');
    _say('started: Direct offered ${Net.instance.directOffered}, on ${Net.instance.directOn}; the core asked for a node $made times; UDP sockets ${await _udpSockets()}; the relay names ${Net.instance.relayHelpers}');
    expect([made, Net.instance.p2p], [0, null]);

    // Switched on: a computer's node comes up at once, on the relay's link helper.
    await Net.instance.setRoute('p2p', true);
    final p2p = Net.instance.p2p!;
    expect(await _until(() => p2p.nodeState == P2pState.up && p2p.nodeWhere?.helper != null, 'the node up on the link helper', most: const Duration(seconds: 30)), isTrue);
    _say('switched on: asked for a node $made times, the node ${p2p.nodeState.name}, on our helper ${p2p.nodeWhere?.helper == 'https://gogho.st:7843'}, ${p2p.nodeWhere?.addresses.length} addresses of its own, UDP sockets ${await _udpSockets()}');
    expect(await _until(() => p2p.devicesOf(b.id).isNotEmpty, 'the phone\'s card', most: const Duration(minutes: 8)), isTrue);

    // C asks both for their cards, says it is up and where (a card of its own), and says its card.
    final cCard = await DeviceCard.make(KeysSigner(c), device: 'c0' * 16, nodeId: 'c1' * 32, now: DateTime.now());
    final where = {'r': 'https://gogho.st:7843', 'a': ['203.0.113.7:4433'], 't': DateTime.now().millisecondsSinceEpoch};
    for (final to in [me.id, b.id]) {
      for (final body in [
        {'t': 'card?', 'h': <String>[]},
        {'t': 'meet', 'c': cCard.toJson(), 'w': where},
        {'t': 'card', 'c': cCard.toJson(), 'w': where, 'h': <String>[]},
      ]) {
        final d = await cBoard.send(cBook.byId(to)!, Envelope(kind: P2p.kind, body: body, ack: false));
        _say('C\'s ${body['t']} to ${to == me.id ? 'A' : 'B'}: by ${d.via}, ${d.handed?.name}');
      }
    }

    // Two texts through the relay, which both ledgers list; two minutes for them to settle, then the relay off.
    expect(await _until(() => came('hub from B', 'hub'), '"hub from B" by the relay', most: const Duration(minutes: 3)), isTrue);
    final peer = Net.instance.byId(b.id)!;
    var d = await Net.instance.send(peer, Envelope(kind: 'text', body: {'t': 'hub from A'}), only: const {'hub'});
    _say('"hub from A": by ${d.via}, answered ${d.acked}');
    await Future<void>.delayed(const Duration(minutes: 2, seconds: 30));
    d = await Net.instance.send(peer, Envelope(kind: 'text', body: {'t': 'go'}), only: const {'hub'});
    _say('"go": by ${d.via}, answered ${d.acked}');
    await Net.instance.setRoute('hub', false);
    _say('the relay\'s route switched off here: off ${Net.instance.board!.off}');

    // The phone's text comes over Direct, and the answer goes back the same way.
    expect(await _until(() => came('direct from B', 'p2p'), '"direct from B" over Direct', most: const Duration(minutes: 2)), isTrue);
    String links() => [for (final l in p2p.carrier.links) '${l.account == b.id ? 'the phone' : 'someone else'} ${l.kind.name}'].join(', ');
    _say('links: ${links()}');
    d = await Net.instance.send(peer, Envelope(kind: 'text', body: {'t': 'direct from A'}));
    _say('"direct from A": by ${d.via}, answered ${d.acked}; tried ${d.tried}');
    expect(d.via, 'p2p');

    // The ledger compared over the link, and what Settings › Routes then shows.
    final ledger = Net.instance.ledger!;
    expect(await _until(() => (ledger.relays[_hub]?.lastChecked ?? 0) > 0, 'the ledger compared over the link', most: const Duration(minutes: 2)), isTrue);
    final r = ledger.relays[_hub]!, now = DateTime.now().millisecondsSinceEpoch;
    _say('Checking the relay shows: "${relayCheckedWords(r.lastChecked, r.devices, now: now)}"; "${relayMatchedWords(r.matched(now))}"; "${relayMadeUpWords(r.madeUp(now), restarts: r.restarts(now))}"; ${r.wrong.isEmpty ? '"It got nothing wrong"' : [for (final w in r.wrong) relayWrongWords(w, 'B')].join('; ')}');

    // The phone switches "Only through link helpers" on, and its next text comes through the helper.
    expect(await _until(() => came('through the helper only', 'p2p'), '"through the helper only" over Direct', most: const Duration(minutes: 2)), isTrue);
    _say('links: ${links()}; the path to the phone\'s node: ${p2p.node.pathTo(p2p.devicesOf(b.id).single.nodeId)?.kind.name}');
    d = await Net.instance.send(peer, Envelope(kind: 'text', body: {'t': 'helper back'}));
    _say('"helper back": by ${d.via}, answered ${d.acked}');

    // C learned nothing of where anyone is: no card, no meet, nothing at all came back to it.
    await Future<void>.delayed(const Duration(seconds: 5));
    _say('C got: ${cGot.isEmpty ? 'nothing' : cGot.join(', ')}; A holds of C: ${p2p.devicesOf(c.id).length} devices, links with C ${p2p.mayLink(c.id)}');
    expect(cGot.where((g) => g.startsWith(P2p.kind)), isEmpty);
    expect([p2p.devicesOf(c.id), p2p.mayLink(c.id)], [isEmpty, false]);

    // Switched off: every link closed, the node stopped and its sockets let go; the library loaded still, and idle.
    final before = await _udpSockets();
    await Net.instance.setRoute('p2p', false);
    final after = await _udpSockets();
    _say('switched off: the direct network ${Net.instance.p2p}, routes ${Net.instance.board!.carriers.map((r) => r.id).toList()}, the node ${p2p.nodeState.name}; UDP sockets $before before, $after after');
    expect([Net.instance.p2p, p2p.nodeState, after], [null, P2pState.off, 0]);
    await Future<void>.delayed(const Duration(seconds: 30));
    _say('half a minute on: UDP sockets ${await _udpSockets()}');
    await cBoard.stop();
    await Net.instance.shutdown();
    Net.p2pNode = null;
  }, timeout: const Timeout(Duration(minutes: 20)));
}
