import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:ghost_messaging/friends/friends.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/hub_carrier.dart' show HubCarrier;
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_messaging/net/switchboard.dart';
import 'package:ghost_messaging/sms.dart';

// A stand-in for what Friends stands on (lib/friends/friends.dart, FriendsPort): the routes and the phone of one
// install, with what it sends handed to another's. For test/friends_test.dart and the screens' pictures.

/// What was sent: to the address the peer was held under ([to]) and to whom by name ([id]).
typedef Sent = ({String to, String id, Envelope envelope, bool metered, bool sealed, Set<String>? only});

class FakePort implements FriendsPort {
  FakePort(this.me);

  /// This phone's number.
  final String me;
  late FakePort other;

  /// Where this phone stands with the other, as android E2e keeps it.
  final Map<String, E2eState> book = {};

  /// The phone keeps the records for numbers; every other device of the account doesn't.
  @override
  bool numbers = true;

  /// The installs in this device's list of friends by username, whatever each stands at.
  final buddies = <String>{};
  @override
  bool knows(String id) => buddies.contains(id);

  /// The relay server's route is up; the other phone is connected to it; it takes what it is given.
  bool up = true;
  bool otherHere = true;
  bool refuses = false;
  bool answers = false;

  /// Where set, the relay refuses what is sent with these words, as the hub route says why (their relay can't be
  /// reached from yours, and the like).
  String? refusedWhy;

  /// The relay server hands what it is given to a connection of the other's that has died: it says it passed it on,
  /// and nothing arrives or answers (what happened in the live test, 2026-11-15).
  bool lost = false;

  /// The routes changed (one came up): what Friends listens for.
  void bump() => _changed.value++;

  final sent = <Sent>[];

  /// When each row kept from a copy was written (GMFB-21).
  final keptAt = <int, int>{};
  final held = <Envelope>[];
  final rows = <int, ({String address, String words, String state})>{};
  final dropped = <int>[];
  final came = <({String address, String words})>[];
  final keysSent = <String>[];
  final _in = StreamController<Received>.broadcast();
  final _acks = StreamController<String>.broadcast();
  final _changed = ValueNotifier<int>(0);

  /// The name of the install at [address], as its key would give it: what the record for that address names, and
  /// what the routes know it by.
  static String idAt(String address) => 'name-of-$address';

  void stand(String address, {String state = 'on', String friend = '', bool hasGhost = true}) {
    book[address] = E2eState(address: address, state: state, friend: friend, hasGhost: hasGhost, id: idAt(address));
    _changed.value++;
  }

  /// The routes reach whoever encryption is on with, by the name of their key, under the address of their record.
  @override
  Peer? peer(String id) {
    for (final s in book.values) {
      if (s.on && s.id == id) return Peer(id: id, key: Uint8List(32), address: s.address);
    }
    return null;
  }

  @override
  bool get internet => up;

  /// What was sent to this account's other devices (GMFB-21), and the other device of this account where there is one.
  final mineSent = <Envelope>[];
  FakePort? twin;

  /// The most a packet on the hub or the direct route carries (HubCarrier.maxPacket), less sealing's few bytes: what is
  /// longer goes by no route, as the switchboard finds (GMFB-53's review, H2).
  static const routeMost = HubCarrier.maxPacket - 64;

  /// Where set, every packet to the account's own devices is refused (the relay's mailbox for them full).
  bool mineRefused = false;

  /// What went by the hub alone ([sendMine]'s hubOnly), by envelope id.
  final hubOnly = <String>{};

  @override
  @override
  Future<Delivery> sendMine(Envelope envelope, {bool hubOnly = false}) async {
    if (envelope.encode().length > routeMost) return Delivery(envelope.id, tried: const ['too big for any route']);
    if (mineRefused) return Delivery(envelope.id, tried: const ['hub: nak full']);
    mineSent.add(envelope);
    if (hubOnly) this.hubOnly.add(envelope.id);
    final t = twin;
    if (t == null) return Delivery(envelope.id, tried: const ['no account here']);
    // As the hub hands it: with the device that sent it (relay/lib/hub.dart toPeerFromDevice).
    t._in.add(Received(Peer(id: 'mine', key: Uint8List(32)), envelope, 'hub', arrived: Arrived('hub', Uint8List(0), device: hubDevice)));
    return Delivery(envelope.id, via: 'hub', handed: Handed.passed);
  }

  @override
  bool isMine(Peer peer) => peer.id == 'mine';

  /// This device's number on the account's list (GMFB-53), and the devices the account lists now (all, where null).
  String device = 'device-${_n++}';
  static int _n = 0;
  Set<String>? onList;
  bool signedIn = true;

  @override
  ({String device, String name})? get thisDevice => signedIn ? (device: device, name: 'Device $device') : null;

  /// This device's name on the hub, which the hub vouches for on what it sends its account's own name.
  String get hubDevice => 'hub-$device';

  /// The account's list as a device holding its key reads it (null: one that can't, a browser).
  List<String>? listing;

  @override
  Future<String?> vouch(String d, String hub) async => (onList?.contains(d) ?? true) && hub == 'hub-$d' ? 'Device $d' : null;

  @override
  Future<List<String>?> listedDevices() async => listing;

  /// The conversations with friends by username this device holds (GMFB-53), and what another device's history added.
  final pastHeld = <String, List<PastRow>>{};
  final pastKept = <String, List<PastRow>>{};

  @override
  Future<List<({String address, List<PastRow> rows})>> history() async => [for (final e in pastHeld.entries) (address: e.key, rows: e.value)];

  @override
  Future<int> keepHistory(String address, List<PastRow> rows) async {
    final kept = pastKept.putIfAbsent(address, () => []);
    var added = 0;
    for (final r in rows) {
      if (kept.contains(r)) continue;
      kept.add(r);
      added++;
    }
    return added;
  }

  @override
  Future<Delivery> send(Peer peer, Envelope envelope, {bool metered = false, bool sealed = true, Set<String>? only}) async {
    sent.add((to: peer.address ?? '', id: peer.id, envelope: envelope, metered: metered, sealed: sealed, only: only));
    // A data text: on its way, and nothing more is known.
    if (only != null && only.contains('sms')) return Delivery(envelope.id, via: 'sms', handed: Handed.passed);
    // Someone who is not the other phone (a member of a group, in a test): the relay takes it, and that is all.
    if (peer.id != idAt(other.me)) return Delivery(envelope.id, via: 'hub', handed: Handed.passed);
    final why = refusedWhy;
    if (why != null) return Delivery(envelope.id, tried: ['hub: $why']);
    if (!up || refuses) {
      if (!metered) return Delivery(envelope.id, tried: const ['hub: not up']);
      other._arrive(me, envelope, sealed);
      return Delivery(envelope.id, via: 'sms', handed: Handed.passed);
    }
    if (lost) return Delivery(envelope.id, via: 'hub', handed: Handed.passed);
    if (!otherHere) {
      held.add(envelope);
      return Delivery(envelope.id, via: 'hub', handed: Handed.held);
    }
    other._arrive(me, envelope, sealed);
    return Delivery(envelope.id, via: 'hub', handed: Handed.passed, acked: envelope.ack);
  }

  /// [envelope] arrives at this phone again from [from], as a resend would bring it.
  void arriveAgain(String from, Envelope envelope) => _arrive(from, envelope, true);

  void _arrive(String from, Envelope envelope, bool sealed) => _in.add(Received(Peer(id: idAt(from), address: from), envelope, 'hub', sealed: sealed));

  /// [envelope] arrives sealed by the install named [id], which the routes hold under [address]: on Android, a member of
  /// a group under whatever its admin wrote.
  /// [device]: the device of this account the hub says sent it (one's own name only).
  void arriveFrom(String id, String address, Envelope envelope, {String? device}) =>
      _in.add(Received(Peer(id: id, key: Uint8List(32), address: address), envelope, 'hub', arrived: device == null ? null : Arrived('hub', Uint8List(0), device: device)));

  /// The other phone's app opens: what the relay server kept is handed over, and each is answered.
  void otherBack() {
    otherHere = true;
    for (final e in held) {
      other._arrive(me, e, true);
      _acks.add(e.id);
    }
    held.clear();
  }

  @override
  Stream<Received> get received => _in.stream;
  @override
  Stream<String> get acked => _acks.stream;
  /// How many times the records were read.
  int statesRead = 0;

  @override
  Future<List<E2eState>> states() async {
    statesRead++;
    return book.values.toList();
  }

  /// What [setFriend] was asked, in order.
  final friendSets = <({String address, String state})>[];

  @override
  Future<void> setFriend(String address, String state) async {
    friendSets.add((address: address, state: state));
    final s = book[address];
    if (s == null) return;
    book[address] = s.withFriend(state);
  }

  @override
  Future<void> offerKeys(String address) async {
    keysSent.add(address);
    // android E2e.offered: on where their key is already here, waiting for it where it is not.
    final s = book[address];
    book[address] = E2eState(address: address, state: s?.state == 'pending' ? 'on' : 'offered', friend: s?.friend ?? '', hasGhost: true, id: s?.id ?? idAt(address));
  }

  @override
  Future<int> storeOut(String address, String words, {int? at}) async {
    final id = rows.length + 1;
    rows[id] = (address: address, words: words, state: 'sending');
    if (at != null) keptAt[id] = at;
    return id;
  }

  @override
  Future<void> rowState(int id, String state) async => rows[id] = (address: rows[id]!.address, words: rows[id]!.words, state: state);
  @override
  Future<void> dropRow(int id) async {
    rows.remove(id);
    dropped.add(id);
  }

  @override
  Future<void> storeIn(String address, String words, int at) async => came.add((address: address, words: words));
  @override
  Listenable get changed => _changed;
  @override
  Future<bool> probe() async => answers;

  /// The addresses whose last packet the relay said waits on it for their relay (each install named as [idAt] names it).
  final Set<String> waiting = {};
  @override
  bool waitingAtRelay(String id) => waiting.any((address) => idAt(address) == id);
}
