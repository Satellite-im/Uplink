import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/homes.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_messaging/net/switchboard.dart';

import 'hub_pair.dart';
import 'relay_net.dart';

/// One install as the tests of relays that talk hold it (test/relays_talk_test.dart): the app's own code from the hub's
/// route up, on a relay of test/support/relay_net.dart. Only the phone's own side is stood in for: the list it keeps,
/// the app's choices, and the key it makes for each pair of friends.

/// Waits for [ok], however long the machine takes (four seconds at most), not for a length of time.
Future<void> until(bool Function() ok, String what) async {
  for (var i = 0; i < 800 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ok(), isTrue, reason: what);
}

/// One install: its key, its relay, and everything of the app's that stands on them.
class RelayApp implements PeerBook, BuddiesPort, BuddiesAcross {
  /// [keys] and [kept] (its choices) are another run's of the same install where given: the app opened again. [now] is
  /// the clock its home records are made by, where a test moves it itself.
  RelayApp(this.net, this.name, MemoryHub relay, {NetKeys? keys, Map<String, String>? kept, Duration busyAgain = const Duration(seconds: 3), DateTime Function()? now}) : keys = keys ?? NetKeys.generate() {
    if (kept != null) choices.addAll(kept);
    signer = KeysSigner(this.keys);
    homes = Homes(signer: signer, read: (k) => choices[k] ?? '', write: (k, v) => choices[k] = v, dial: net.appDial, answerWithin: const Duration(seconds: 2), busyAgain: busyAgain, now: now);
    buddies = Buddies(this, spread: const Duration(hours: 1));
    _use(relay);
  }

  final RelayNet net;
  final String name;
  final NetKeys keys;
  late final KeysSigner signer;
  @override
  late final Homes homes;
  late final Buddies buddies;
  late HubCarrier hub;
  Switchboard? board;
  late MemoryHub relay;

  /// The app's choices, and the friends list as the phone keeps it.
  final Map<String, String> choices = {};
  String list = '[]';

  /// What friends wrote, and what was answered as having arrived.
  final List<({String from, String text})> texts = [];
  final List<String> acked = [];
  final _in = StreamController<({String from, Envelope envelope})>.broadcast();
  final _hellos = StreamController<({String from, Envelope envelope})>.broadcast();
  final List<StreamSubscription<Object?>> _subs = [];

  String get id => keys.id;

  void _use(MemoryHub to) {
    relay = to;
    hub = HubCarrier(url: to.url, signer: signer, retry: const Duration(milliseconds: 20), dial: to.dial);
    homes.attach(hub);
    final b = board = Switchboard(me: id, peers: this, carriers: [hub]);
    _subs.add(b.received.listen((r) {
      if (r.envelope.kind == 'text') texts.add((from: r.peer.id, text: '${r.envelope.body['t']}'));
      _in.add((from: r.peer.id, envelope: r.envelope));
    }));
    _subs.add(b.strangers.listen((s) => _hellos.add((from: s.from, envelope: s.envelope))));
    _subs.add(b.acked.listen(acked.add));
  }

  /// Signs in to its relay and claims its username there.
  Future<void> start() async {
    await hub.start();
    await until(() => hub.state.value == CarrierState.up, '$name never signed in: ${hub.problem}');
    final claimed = hub.handles.firstWhere((m) => m['dir'] == 'claim' || m['dir'] == 'err');
    if (hub.sayHandles({'dir': 'claim', 'name': name})) {
      final m = await claimed.timeout(const Duration(seconds: 2), onTimeout: () => const {});
      claimedName = m['ok'] == true;
    }
    await homes.ensure();
    await buddies.start();
  }

  /// Whether its relay keeps usernames and gave it this one.
  bool claimedName = false;

  /// The app closed: its connection goes, as the relay sees it.
  Future<void> away() async {
    await hub.stop();
    await until(() => relay.hub.connected == 0 || !relay.pairs.any((p) => p.isOpen), '$name never left');
  }

  Future<void> back() async {
    await hub.start();
    await until(() => hub.state.value == CarrierState.up, '$name never came back');
  }

  /// Moves to another relay, as Settings › Routes does (Net.setHub): the next home record is made and given to the
  /// relay being left, then the route is made again for the new one.
  Future<void> moveTo(MemoryHub to) async {
    await homes.moveTo(to.url);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await hub.stop();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await board?.dispose();
    _use(to);
    await hub.start();
    await until(() => hub.state.value == CarrierState.up, '$name never signed in to the new relay');
    hub.sayHandles({'dir': 'claim', 'name': name});
  }

  /// Writes [words] to the friend [to], sealed, by the relay.
  Future<Delivery> write(RelayApp to, String words) => board!.send(byId(to.id)!, Envelope(kind: 'text', body: {'t': words}), only: const {'hub'});

  Future<void> stop() async {
    buddies.dispose();
    homes.dispose();
    for (final s in _subs) {
      await s.cancel();
    }
    await hub.stop();
    await board?.dispose();
  }

  // --- the people the routes reach: friends, with the key the phone makes for each pair (android Buddies.kt) ---------
  @override
  Peer? byId(String id) {
    final b = buddies.byId(id);
    if (b == null || !const {'yes', 'asked', 'invited'}.contains(b.state)) return null;
    final pair = NetCrypto.conversationKey(keys, base64Decode(b.key));
    return pair == null ? null : Peer(id: id, key: NetCrypto.netKey(pair), address: '@${b.username}');
  }

  // --- what Buddies stands on ----------------------------------------------------------------------------------------
  @override
  Future<({String id, String key})> me() async => (id: id, key: base64Encode(keys.public));
  @override
  String? get username => name;
  @override
  String get displayName => '';
  @override
  String get bio => '';

  @override
  Future<({String id, String key})?> whois(String username) async {
    final answer = hub.handles.firstWhere((m) => m['dir'] == 'whois' && m['name'] == username && !m.containsKey('at'));
    hub.sayHandles({'dir': 'whois', 'name': username});
    final m = await answer.timeout(const Duration(seconds: 2));
    return m['id'] is String ? (id: m['id'] as String, key: m['key'] as String) : null;
  }

  @override
  Future<void> keep(String json) async => list = json;
  @override
  Future<String> kept() async => list;

  @override
  Future<bool> send(String id, Envelope envelope, {bool sealed = true}) async => (await board!.send(byId(id) ?? Peer(id: id), envelope, sealed: sealed, only: const {'hub'})).sent;

  @override
  Stream<({String from, Envelope envelope})> get received => _in.stream;
  @override
  Stream<({String from, Envelope envelope})> get greetings => _hellos.stream;

  @override
  Listenable get homesChanged => homes;
  @override
  bool passedOn(String id) => hub.passedOn(id);
  @override
  String? refusedWhy(String id) => hub.refusedWhy[id];
  @override
  String recall(String key) => choices[key] ?? '';
  @override
  void remember(String key, String value) => choices[key] = value;
}

