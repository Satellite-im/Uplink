import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/forward_secrecy.dart' show MemoryFsStore;
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/net/hub_link.dart';
import 'package:ghost_messaging/net/ledger.dart';
import 'package:ghost_messaging/net/p2p/node.dart';
import 'package:ghost_messaging/net/p2p/p2p.dart';
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_messaging/net/switchboard.dart';
import 'package:ghost_relay/hub.dart';

import 'fake_p2p.dart';
import 'hub_pair.dart';

/// Installs that talk as the app's do, with nothing real under them: a real hub in memory (hub_pair.dart), the
/// direct network's stand-in (fake_p2p.dart), and one clock a test moves by hand. Each [Install] is wired as
/// lib/net/net.dart wires the app: a hub route and the direct route on one switchboard, the direct network hearing
/// the switchboard and being told the relay's link helpers.
///
///   final w = World();
///   final a = w.install(w.account('maya')), b = w.install(w.account('sam'));
///   w.friends(a, b);
///   await a.start();
///   await b.start();                      // each now holds the other's card
///   await w.relayGone();                  // nothing answers at the relay
///   await a.text(b.account, 'still here') // …so it goes straight
class World {
  World({List<String> helpers = const [], this.ledgers = false}) {
    // Where the installs keep ledgers, the relay keeps the test's time too: what it says of when it started is held to
    // the installs' clocks (lib/net/ledger.dart).
    memory = MemoryHub(Hub(helpers: helpers, now: ledgers ? clock.now : null));
  }

  /// Whether each install keeps a ledger and compares it over direct links (lib/net/ledger.dart), as the app does where
  /// it has the direct route. Off unless asked for: what it says over links would be counted in the direct route's own
  /// tests. An install can say otherwise for itself ([Install.ledger]).
  final bool ledgers;

  final clock = FakeClock();
  late final mesh = FakeP2pMesh(clock: clock);

  /// The relay's hub, in memory. Put another in its place to stand for a relay that started again.
  late MemoryHub memory;
  final installs = <Install>[];

  Account account(String name) => Account(name);

  /// An install of [account]: a phone's unless [computer], whose node is up whenever Direct is on. [ledger]: whether it
  /// keeps a ledger and compares it, where not as the world says ([ledgers]).
  Install install(Account account, {bool computer = false, P2pPolicy? policy, String network = 'home', List<Carrier> also = const [], bool? ledger}) {
    final i = Install._(this, account, policy ?? (computer ? const P2pPolicy.computer() : const P2pPolicy()), network, also)..keepsLedger = ledger ?? ledgers;
    installs.add(i);
    return i;
  }

  /// [a] and [b] are friends, as each has the other in its list; one that is running watches the other's coming and
  /// going at the relay from now (as Net.refresh has the hub watch the people).
  void friends(Install a, Install b) {
    a.friends.add(b.account);
    b.friends.add(a.account);
    for (final (i, other) in [(a, b), (b, a)]) {
      if (i.running) i.hub.watch([other.account.id]);
    }
  }

  /// Lets what is ready to run, run.
  Future<void> settle() => clock.settle();

  /// Waits for [ok] to come true as things settle; says [what] where it never does.
  Future<void> until(bool Function() ok, String what) async {
    for (var i = 0; i < 40 && !ok(); i++) {
      await clock.settle(5);
    }
    if (!ok()) throw StateError('never: $what');
  }

  /// The relay is gone for everyone: nothing answers there, and every connection to it drops.
  Future<void> relayGone() async {
    memory.down = true;
    for (final p in memory.pairs.toList()) {
      p.cut();
    }
    await settle();
  }

  /// The relay answers again, and every install that wants it dials now.
  Future<void> relayBack() async {
    memory.down = false;
    for (final i in installs) {
      if (i.running) i.hub.nudge();
    }
    await settle();
  }

  Future<void> stop() async {
    for (final i in installs.toList()) {
      await i.stop();
    }
  }
}

/// An account: its identity, and the key its devices seal what they say to each other with (Me.mineKey in the app).
class Account {
  Account(this.name)
      : keys = NetKeys.generate(),
        mineKey = NetCrypto.randomBytes(32);
  final String name;
  final NetKeys keys;
  final Uint8List mineKey;
  String get id => keys.id;
  @override
  String toString() => name;
}

/// One device of an account: what it keeps (secrets and choices, as the app's stores), its node, its routes.
class Install implements PeerBook {
  Install._(this.world, this.account, this.policy, this.network, this.also, {String? device}) : device = device ?? NetCrypto.hex(NetCrypto.randomBytes(16));

  /// [was]'s app deleted and put back on the same device: the same account and device name, nothing kept (a test puts
  /// back what outlives an app, as an iPhone's Keychain does).
  factory Install.again(Install was) {
    final i = Install._(was.world, was.account, was.policy, was.network, was.also, device: was.device)..keepsLedger = was.keepsLedger;
    i.friends.addAll(was.friends);
    i.known.addAll(was.known);
    was.world.installs.add(i);
    return i;
  }

  final World world;
  final Account account;
  final String device;
  final P2pPolicy policy;
  final String network;

  /// Other routes on its switchboard, beside the hub's and the direct one.
  final List<Carrier> also;

  /// What the app keeps where it keeps its keys, and with its choices. They outlive a [restart].
  final secrets = LockableStore(), plain = MemoryFsStore();

  /// Set before a start, the node made for it fails to start with these words ([FakeP2pNode.failStarts]).
  String? startFails;

  /// Set before a start, the node made for it never answers a stop or what a key makes ([FakeP2pNode.hangs]).
  bool coreHangs = false;

  /// While set, the account's key will not sign (a keystore that refuses); [signs] counts each time it is asked.
  bool signFails = false;
  int signs = 0;

  /// Its friends: whom the direct route links with.
  final Set<Account> friends = {};

  /// People a key is held for and the routes reach, who are not friends: someone who has only asked, a member of a
  /// group this install is in.
  final Set<Account> known = {};

  /// Whether an account is signed in here: its own other devices are then reached through its own name.
  bool signedIn = true;

  /// Set before a start, the app starts with Direct switched off in Settings › Routes.
  bool startOff = false;

  late FakeP2pNode node;
  late HubCarrier hub;
  late P2p p2p;
  late Switchboard board;
  bool running = false;

  /// Whether it keeps a ledger and compares it over direct links ([World.ledgers]); and, where it does, the ledger and
  /// its comparing as the app makes them (lib/net/net.dart).
  bool keepsLedger = false;
  Ledger? ledger;
  LedgerCheck? check;

  /// What it sent and holds unanswered, beside the switchboard's own five minutes, as Friends' list of what is
  /// unanswered does: given to the comparing to send again ([LedgerCheck.holders]).
  final outbox = <String, Envelope>{};


  /// The connection to the relay it dialled last, as the relay's end holds it: a test makes the relay drop what it says
  /// on it ([HubPair.dropToApp]). Each new one is given [dropToApp] as it is made.
  HubPair? pair;
  bool Function(Object said)? dropToApp;
  StreamSubscription<Received>? _sub;

  /// Everything the switchboard passed on, since the first start.
  final got = <Received>[];

  /// What this install heard about the direct network (`p2p` envelopes), as "card from sam", and the words of the
  /// texts it got.
  List<String> get heard => [for (final r in got) if (r.envelope.kind == P2p.kind) '${r.envelope.body['t']} from ${_nameOf(r.peer.id)}'];
  List<String> get texts => [for (final r in got) if (r.envelope.kind == 'text') '${r.envelope.body['t']}'];

  String _nameOf(String id) => id == account.id ? account.name : [...friends, ...known].where((a) => a.id == id).firstOrNull?.name ?? id.substring(0, 6);

  final Map<String, Peer> _peers = {};

  /// [other] as this install's routes know them: sealed with the key the two accounts share.
  Peer to(Account other) => _peers[other.id] ??= Peer(id: other.id, key: NetCrypto.netKey(NetCrypto.conversationKey(account.keys, other.keys.public)!), address: '@${other.name}', name: other.name);

  /// This account's own other devices, as one peer.
  Peer get mine => Peer(id: account.id, key: account.mineKey);

  @override
  Peer? byId(String id) {
    if (id == account.id) return signedIn ? mine : null;
    for (final a in [...friends, ...known]) {
      if (a.id == id) return to(a);
    }
    return null;
  }

  /// The app opens: its node made (not started), its routes set up and started, and what the direct network keeps
  /// read.
  Future<void> start() async {
    node = world.mesh.node(network: network)
      ..failStarts = startFails
      ..hangs = coreHangs;
    hub = HubCarrier(
      url: world.memory.url,
      signer: KeysSigner(account.keys),
      retry: const Duration(hours: 1),
      now: world.clock.now,
      dial: (url) async {
        final link = await world.memory.dial(url);
        pair = world.memory.pairs.last..dropToApp = dropToApp;
        return _DeviceLink(link, device);
      },
    );
    p2p = P2p(
      node: node,
      signer: _InstallSigner(this),
      device: device,
      secrets: secrets,
      plain: plain,
      friends: () => [for (final f in friends) to(f)],
      mine: () async => signedIn ? mine : null,
      present: (id) => hub.here.value.contains(id),
      policy: policy,
      now: world.clock.now,
      timer: world.clock.timer,
    );
    board = Switchboard(me: account.id, peers: this, carriers: [hub, p2p.carrier, ...also], now: world.clock.now, timer: world.clock.timer);
    if (startOff) board.off.add(p2p.carrier.id);
    _sub = board.received.listen(got.add);
    if (keepsLedger) {
      final l = ledger = Ledger(store: plain, me: account.id, device: device, isFriend: (id) => friends.any((f) => f.id == id), now: world.clock.now, timer: world.clock.timer);
      board.log = l;
      await l.load();
      check = LedgerCheck(ledger: l, board: board, p2p: p2p, relay: () => hub, now: world.clock.now, timer: world.clock.timer)
        ..holders.add((peer, id) => outbox[id])
        ..start();
    }
    hub.helpers.addListener(_helpers);
    // Who is connected to the relay, as the app watches the people it reaches (Net._apply).
    hub.watch([for (final a in [...friends, ...known]) a.id]);
    hub.presence.addListener(_presence);
    p2p.attach(board);
    running = true;
    await board.start();
    // Signed in to the relay, where it is there, and handed what it kept, before what the direct network keeps has
    // been read: one of the orders an app's start can take, and the one in which nothing is said twice.
    await world.settle();
    await p2p.tryLoad();
    await world.settle();
  }

  void _helpers() => p2p.setHelpers(hub.helpers.value);
  void _presence() => p2p.presenceChanged();

  /// The app closes. What it keeps stays.
  Future<void> stop() async {
    if (!running) return;
    running = false;
    // (A core a test made hang is let answer: the clock that would time it out is the test's to move.)
    node.hangs = false;
    hub.helpers.removeListener(_helpers);
    hub.presence.removeListener(_presence);
    await _sub?.cancel();
    await check?.stop();
    check = null;
    await ledger?.shutdown();
    ledger = null;
    await board.stop();
    await p2p.shutdown();
    await board.dispose();
    await world.settle();
  }

  /// The app closed and opened again: a new node, the same key and the same things kept.
  Future<void> restart() async {
    await stop();
    await start();
  }

  /// How many times this install's node has dialled [other]'s.
  int dialled(Install other) => world.mesh.dials.where((d) => identical(d.from, node) && d.to == other.p2p.nodeId).length;

  /// Sends [words] to [to] as a friend's text, by [only] those routes where given. Held in [outbox] until it is
  /// answered, as Friends holds what it sent.
  Future<Delivery> text(Account to, String words, {Set<String>? only, bool urgent = false}) async {
    final e = Envelope(kind: 'text', body: {'t': words}, at: world.clock.ms);
    outbox[e.id] = e;
    late final StreamSubscription<String> answered;
    answered = board.acked.listen((id) {
      if (id != e.id) return;
      outbox.remove(id);
      unawaited(answered.cancel());
    });
    final d = await board.send(this.to(to), e, only: only, urgent: urgent);
    if (d.acked) {
      outbox.remove(e.id);
      unawaited(answered.cancel());
    }
    return d;
  }

  @override
  String toString() => '${account.name}\'s ${policy.stayUp ? 'computer' : 'phone'}';
}

/// The account's key as this install's keystore holds it: asked each time, and able to refuse.
class _InstallSigner implements NetSigner {
  _InstallSigner(this._install);
  final Install _install;
  @override
  String get id => _install.account.id;
  @override
  Uint8List get publicKey => _install.account.keys.public;
  @override
  Future<Uint8List> sign(List<int> message) async {
    _install.signs++;
    if (_install.signFails) throw StateError('the keystore would not sign');
    return NetCrypto.sign(_install.account.keys, message);
  }
}

/// A secret store that can be locked, as an iPhone's Keychain is before its first unlock: nothing is read or written.
/// With [gate] set, a read waits until it completes, as a slow store's does.
class LockableStore extends MemoryFsStore {
  bool locked = false;
  Completer<void>? gate;

  /// How many reads are waiting at the [gate] now.
  int waiting = 0;
  @override
  Future<String?> read(String name) async {
    if (locked) throw StateError('locked');
    final g = gate;
    if (g != null) {
      waiting++;
      await g.future;
      waiting--;
    }
    return super.read(name);
  }

  @override
  Future<void> write(String name, String value) async {
    if (locked) throw StateError('locked');
    return super.write(name, value);
  }
}

/// A link to the hub that says which device it is. The app says one device for the whole process
/// ([HubCarrier.device]); here several devices, some of one account, are in one.
class _DeviceLink implements HubLink {
  _DeviceLink(this._link, this._device);
  final HubLink _link;
  final String _device;

  @override
  Stream<Object> get said => _link.said;

  @override
  void say(Object message) {
    if (message is String && message.contains('"sig"')) {
      final hello = jsonDecode(message) as Map<String, dynamic>;
      hello['device'] = _device;
      return _link.say(jsonEncode(hello));
    }
    _link.say(message);
  }

  @override
  Future<void> close() => _link.close();
}

/// A route of nothing, for what comes after the direct one: what one end sends its [twin] is handed.
class PlainCarrier implements Carrier {
  PlainCarrier(this.id, {this.traits = const CarrierTraits(maxPacket: 4096, ackWait: Duration(milliseconds: 200))});
  @override
  final String id;
  @override
  String get name => id;
  @override
  String get about => '';
  @override
  final CarrierTraits traits;
  @override
  final ValueNotifier<CarrierState> state = ValueNotifier(CarrierState.off);
  @override
  String? problem;
  PlainCarrier? twin;
  final carried = <Uint8List>[];

  /// Whom each thing carried was for, by name.
  final to = <String>[];
  final _arrived = StreamController<Arrived>.broadcast();
  @override
  Stream<Arrived> get arrived => _arrived.stream;
  @override
  Future<void> start() async => state.value = CarrierState.up;
  @override
  Future<void> stop() async => state.value = CarrierState.off;
  @override
  bool reaches(Peer peer) => true;
  @override
  Future<Handed> send(Peer peer, Uint8List packet) async {
    carried.add(packet);
    to.add(peer.id);
    twin?.take(packet);
    return Handed.passed;
  }

  /// [packet] comes by this route, vouched for as [from]'s where given.
  void take(Uint8List packet, {String? from}) => _arrived.add(Arrived(id, packet, from: from));

  static (PlainCarrier, PlainCarrier) pair(String id) {
    final a = PlainCarrier(id), b = PlainCarrier(id);
    a.twin = b;
    b.twin = a;
    return (a, b);
  }
}

/// The handshake that opens a direct stream (lib/net/p2p/p2p_carrier.dart), worked out here apart from the route, so a
/// test holds the route to its bytes:
///
///     [0][2][a nonce: 16 bytes]                    each end, as the stream opens
///     [0][3][HMAC-SHA256(link key, "ghost-p2p link v2\n" | from account (16) | from node (32) | to account (16) |
///            to node (32) | the other end's nonce (16) | this end's (16))]
///
/// The end that dialled proves first, once the other's nonce has come; the end dialled proves back once that proof
/// checks out. The link key is made from what the two accounts seal their packets with (P2p.linkKey).
abstract final class LinkWords {
  static final _v2 = utf8.encode('ghost-p2p link v2\n');

  static Uint8List linkKey(Uint8List pairKey) => NetCrypto.derive(pairKey, 'p2p link');

  static Uint8List nonce(List<int> n) => Uint8List.fromList([0, 2, ...n]);

  static Uint8List proof(Uint8List linkKey, {required String fromAccount, required String fromNode, required String toAccount, required String toNode, required List<int> toNonce, required List<int> fromNonce}) =>
      Uint8List.fromList([0, 3, ...NetCrypto.hmac(linkKey, [..._v2, ...NetCrypto.unhex(fromAccount), ...NetCrypto.unhex(fromNode), ...NetCrypto.unhex(toAccount), ...NetCrypto.unhex(toNode), ...toNonce, ...fromNonce])]);
}

/// One end of a direct stream played by hand ([LinkWords]), as [account]'s device at [node] would play it, toward
/// [them]: its nonce at once, then its proof when its turn comes. What the other end says is in [heard]; what it says
/// after the handshake, in [frames]. [proves] false never proves (a device that takes a stream and says nothing more).
class HandEnd {
  HandEnd(this.stream, {required this.linkKey, required this.account, required this.node, required this.them, this.proves = true}) : nonce = NetCrypto.randomBytes(16) {
    stream.frames.listen(_heard, onDone: () => done = true, onError: (Object _) => done = true);
    unawaited(stream.add(LinkWords.nonce(nonce)).catchError((Object _) {}));
  }

  final P2pStream stream;
  final Uint8List linkKey;
  final String account, node, them;
  final bool proves;
  final Uint8List nonce;

  /// The other end's nonce, once it has come.
  Uint8List? theirs;

  /// Whether the other end's proof has come and is the one its account would make.
  bool proved = false;
  bool done = false;
  final heard = <Uint8List>[];
  final frames = <Uint8List>[];

  bool get _dialled => !stream.incoming;

  Uint8List _mine() => LinkWords.proof(linkKey, fromAccount: account, fromNode: node, toAccount: them, toNode: stream.nodeId, toNonce: theirs!, fromNonce: nonce);
  Uint8List _theirs() => LinkWords.proof(linkKey, fromAccount: them, fromNode: stream.nodeId, toAccount: account, toNode: node, toNonce: nonce, fromNonce: theirs!);

  void _heard(Uint8List f) {
    heard.add(f);
    if (theirs == null) {
      if (f.length == 18 && f[0] == 0 && f[1] == 2) {
        theirs = f.sublist(2);
        if (_dialled && proves) unawaited(stream.add(_mine()).catchError((Object _) {}));
      }
      return;
    }
    if (!proved && f.length == 34 && f[0] == 0 && f[1] == 3) {
      proved = _same(f, _theirs());
      if (proved && !_dialled && proves) unawaited(stream.add(_mine()).catchError((Object _) {}));
      return;
    }
    frames.add(f);
  }

  static bool _same(List<int> a, List<int> b) => a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

  Future<void> add(Uint8List frame) => stream.add(frame);
}
