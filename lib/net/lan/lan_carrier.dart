import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../carrier.dart';
import '../crypto.dart';
import '../hub_carrier.dart' show HubCarrier;
import 'lan_wire.dart';
import 'lan_words.dart';

/// How the local network route keeps time: how often it says it is here, how long it believes what it heard, how long
/// a link may be silent. A phone's runs only while the app is in use ([sleepsAway]); a computer's whenever it is on.
class LanPolicy {
  const LanPolicy({
    this.beatEvery = const Duration(seconds: 5),
    this.seenFor = const Duration(seconds: 30),
    this.yieldFor = const Duration(seconds: 2),
    this.dialFor = const Duration(seconds: 3),
    this.knockFor = const Duration(seconds: 1),
    this.proveFor = const Duration(seconds: 5),
    this.pingEvery = const Duration(seconds: 20),
    this.quietFor = const Duration(seconds: 60),
    this.redialAfter = const Duration(seconds: 15),
    this.sweepEvery = const Duration(seconds: 10),
    this.rerunAfter = const Duration(hours: 6),
    this.sleepsAway = true,
  });
  const LanPolicy.computer() : this(sleepsAway: false);

  /// How often a beacon is said, and how long a device heard from is taken to be on the network still.
  final Duration beatEvery, seenFor;

  /// How long the device with the greater name waits for the other to connect before connecting itself.
  final Duration yieldFor;

  /// How long a connection is given to be made; how long one that was made to this device has to say its knock; and
  /// how long each step of proving after that is given.
  final Duration dialFor, knockFor, proveFor;

  /// A link with nothing said on it this long is said a word on; with nothing heard on it [quietFor], closed.
  final Duration pingEvery, quietFor;

  /// A device that couldn't be connected to is not tried again for this long.
  final Duration redialAfter;
  final Duration sweepEvery;

  /// With no link open, the route starts over under a new name after this long ([LanCarrier] "Its name").
  final Duration rerunAfter;

  /// Whether the route closes everything while the app is put away (a phone's).
  final bool sleepsAway;
}

/// A link to one device on the network, as Settings › Routes lists it.
@immutable
class LanLinked {
  const LanLinked({required this.peer, required this.address});

  /// The account whose device it is (this account's own name for one of its own).
  final String peer;
  final String address;
}

/// The local network route (GMFB-24: "A LAN route: two devices on the same network find each other (mDNS or similar)
/// and exchange sealed packets directly"; docs/network.md). Straight between this device and the devices of its own
/// account and its friends that are on the same Wi-Fi or wired network, with no server and no internet: it comes
/// after the relay and the direct route in the order (Switchboard.order), the way through when neither can carry
/// something, and by itself when there is no internet at all.
///
/// **Finding each other.** Every few seconds a device says a beacon on each private network it has an address on
/// (lan_words.dart, [LanBeacon]): its door's port and, for each person it would link with, a mark only that person's
/// devices can recognise, made from the key the two accounts already seal with and good for one ten minutes, one run
/// of the route and the one address it is said from. It names nobody. Marks of noise that stay as the real ones do
/// stand beside them, in the order of their bytes and as many whether or not the person is shown as Invisible, so the
/// network learns that some copy of the app is here and roughly how many people it could have at most. A device that
/// hears a mark of its own knows whose device said it and where; the same beacon said again by anyone else, from an
/// address of their own, carries nothing anyone recognises.
///
/// **Linking.** One of the two connects to the other's door (the one whose run has the lesser name at once, the other
/// if nothing has come after [LanPolicy.yieldFor]) and each proves to the other that it holds the pair's key, over
/// both accounts, both devices' runs and a nonce from each end, so a proof is good for that connection alone:
///
///     [1][run: 8][nonce: 16][ten minutes: 4][knock: 16]     the one connecting; the knock says who to whom
///     [2][nonce: 16][proof: 32]                            the one connected to, once the knock is one of its people's
///     [3][proof: 32]                                       the one connecting
///     [4][sealed: a count (8), a kind (1), then a packet]  everything after, each way under a key of its own
///
/// Nothing is taken from a connection before its proof, nothing sent on it, and one whose knock is nobody's is closed
/// without a word. Everything after is sealed for the link (AES-256-GCM under keys made for it from the transcript)
/// and counted, so the network sees neither the accounts' names in the packets' headers nor a frame said twice. The
/// packets inside are sealed already, as on every route.
///
/// **Whom.** Only the people [people] names: the app gives it this account's own devices and its friends (never the
/// other members of a group, never someone who only asked), as the direct route. While the person chose Invisible,
/// only their own devices are marked or linked with. Only at private addresses on a network this device has an
/// address on ([isLanAddress], [sameNet]): nothing is heard from, connected to or taken from any other.
///
/// **Its name.** A run of the route has a random name and a door of its own, which is all the network can know it by.
/// It starts over under a new one whenever the networks it is on change, whenever the person goes Invisible or comes
/// back from it (so a friend's device that knew it by the old one sees that one go), and every few hours while no
/// link is open. The address it speaks from can't be hidden while it says anything at all: Invisible changes who can
/// tell whose the device is, not that a copy of the app is there.
///
/// **What others can make it do** (the review of 2026-11-26; each was unbounded, or bounded by something shared):
/// everything it knows of a device is kept by the account and the run together, so one friend's device can't speak
/// under another's name; an account's devices hold at most [mostPerAccount] links; an address may bring a few runs to
/// look at a minute and everyone together so many, and a run that matched is known from then on without another look;
/// connections are made to a few devices at a time and a few a minute at one address; a door always takes a
/// connection from where a device it recognised was heard, and the rest share what room there is, each given a second
/// to knock; a link that says more than a link may is closed. Stopped, it leaves nothing open and no timer.
///
/// **Carrying.** A packet goes to every device of theirs a link is open to; where none is and one of theirs was heard
/// lately, it is connected to first (a connection already being made is waited for). Passed once a link took it;
/// otherwise it throws and the switchboard goes on. Nothing is ever kept. It holds links of its own ([LiveLinks]):
/// where the relay only kept something for someone who is on this network, it goes by the link too.
class LanCarrier implements Carrier, LiveLinks {
  LanCarrier({required this.me, required this.ground, required this.people, this.policy = const LanPolicy(), DateTime Function()? now, bool Function(String address)? allowed, Random? random})
      : _now = now ?? DateTime.now,
        _allowedBy = allowed,
        _random = random ?? Random.secure();

  /// This account's name (32 hex digits).
  final String me;
  final LanGround ground;

  /// Whom this device says it is here to and links with, each with the key the two seal with: this account's own
  /// devices (as one peer, by this account's name and its own key) and its friends.
  final List<Peer> Function() people;
  final LanPolicy policy;
  final DateTime Function() _now;
  final bool Function(String address)? _allowedBy;
  final Random _random;

  static const routeId = 'lan', label = 'Local network';

  /// What the route is, in words: its row in Settings › Routes says them whether it is on or off.
  static const aboutWords =
      'Straight between your devices and your friends\' while they are on the same Wi-Fi or wired network as this one, with no server and no internet. Their devices learn this device\'s address on that network. The network sees that a copy of the app is here, never who you are or what is said.';

  /// The longest packet carried: the relay's, so a packet made for one route fits the other.
  static const maxPacket = HubCarrier.maxPacket;

  /// The most proved links held with one run of one account's device (a newer one takes the oldest's place), with one
  /// account's devices together (the same), and in all (one more is not taken).
  static const mostLines = 2, mostPerAccount = 8, mostLinks = 64;

  /// Connections not yet proved: in all and from one address, for those from no address a recognised device was heard
  /// at (one from such an address is always taken); and knocks taken from one address in a minute.
  static const mostProving = 16, mostProvingFrom = 4, knocksAMinute = 12;

  /// Runs not seen before whose marks are looked at (each costs a mark for every person): so many at once and a
  /// minute from one address, and so many at once and a second from everyone together.
  static const runsFromOne = 6, runsAtOnce = 120, runsASecond = 10;

  /// Beacons taken in: so many at once, and so many a second after. The rest are dropped before anything is done with
  /// them ([droppedBeacons]). Those of a run already known at the address they come from have a count of their own
  /// ([knownAtOnce], [knownASecond]), so no flood of anyone else's keeps a device that is here from being heard.
  static const beaconsAtOnce = 200, beaconsASecond = 100, knownAtOnce = 300, knownASecond = 300;

  /// Devices kept as heard for one account at a time: one more takes the place of the one heard longest ago.
  static const mostSeenOf = 16;

  /// Connections being made at once, made in a minute to one address, and made in all: so many at once and one more
  /// every few seconds after ([dialsAtOnce], [dialsASecond]).
  static const mostDialing = 4, dialsAMinuteTo = 3, dialsAtOnce = 16, dialsASecond = 0.25;

  /// What one link may bring: so many packets at once and so many more each second after ([lineBurst],
  /// [linePerSecond]), and an account's devices together ([accountBurst], [accountPerSecond]); what comes beyond is
  /// dropped and counted ([dropped]): a packet that matters is sent again until it is answered. And frames of any kind
  /// ([frameBurst], [framePerSecond]): a link that says more is closed, before the frame is so much as opened.
  static const lineBurst = 100, linePerSecond = 10, accountBurst = 150, accountPerSecond = 15, frameBurst = 400, framePerSecond = 200;
  int dropped = 0, droppedBeacons = 0;

  @override
  String get id => routeId;
  @override
  String get name => label;
  @override
  String get about => aboutWords;
  @override
  CarrierTraits get traits => const CarrierTraits(maxPacket: maxPacket);
  @override
  final ValueNotifier<CarrierState> state = ValueNotifier(CarrierState.off);
  @override
  String? problem;

  final _arrived = StreamController<Arrived>.broadcast();
  @override
  Stream<Arrived> get arrived => _arrived.stream;

  /// Goes up whenever who is seen or linked changes: Settings › Routes draws from it.
  final ValueNotifier<int> changed = ValueNotifier(0);

  /// This run of the route, to the others on the network: eight random bytes, and a secret its noise is made from,
  /// both new each time the route opens. When it opened, and which opening this is: whatever was begun under one
  /// opening looks at [_session] after every wait, and does nothing more once the route has closed or opened again.
  Uint8List _run = Uint8List(LanBeacon.instanceLength);
  Uint8List _noise = Uint8List(32);
  String _runName = '';
  DateTime _openedAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _session = 0;

  LanAir? _air;
  LanDoor? _door;
  List<String> _addresses = const [];
  Timer? _beatTimer, _sweepTimer, _againTimer;
  bool _wanted = false, _away = false, _invisible = false, _opening = false;

  /// The devices heard lately, by account and run ([_keyOf]); the links, proved; the connections being made, by the
  /// same; the timers of those waited on to connect first; and when one last couldn't be connected to.
  final Map<String, _Seen> _seen = {};
  final List<_Link> _links = [];
  final Map<String, Future<bool>> _dials = {};
  final Map<String, Timer> _yields = {};
  final Map<String, DateTime> _failed = {};

  /// When a connection was last made to each address ([dialsAMinuteTo]).
  final Map<String, List<DateTime>> _dialled = {};

  /// Beacons already looked at that named nobody of ours, by run, ten minutes, port and address: not looked at again.
  final LinkedHashSet<String> _strange = LinkedHashSet();
  static const mostStrange = 512;

  /// What may still be taken in now: beacons, runs to look at in all, and from each address.
  late _Bucket _beaconBudget = _Bucket(beaconsAtOnce, beaconsASecond.toDouble(), _now());
  late _Bucket _knownBudget = _Bucket(knownAtOnce, knownASecond.toDouble(), _now());
  late _Bucket _lookBudget = _Bucket(runsAtOnce, runsASecond.toDouble(), _now());
  late _Bucket _dialBudget = _Bucket(dialsAtOnce, dialsASecond, _now());
  final Map<String, _Bucket> _lookFrom = {};

  /// Connections not yet proved, each with the address it came from; and when each address last knocked.
  final Map<LanWire, String> _proving = {};
  final Map<String, List<DateTime>> _knocks = {};

  /// What each account's devices may still bring now ([accountBurst]).
  final Map<String, _Bucket> _accounts = {};

  /// The key each person's marks are made with, with the key it was made from.
  final Map<String, ({Uint8List from, Uint8List key})> _keys = {};

  static String _keyOf(String peer, String run) => '$peer:$run';

  Uint8List? _lanKey(Peer p) {
    final pair = p.key;
    if (pair == null) return null;
    final had = _keys[p.id];
    if (had != null && listEquals(had.from, pair)) return had.key;
    final key = LanWords.keyOf(pair);
    _keys[p.id] = (from: pair, key: key);
    return key;
  }

  /// Everyone it would say it is here to and link with, shown or not: what a beacon's length goes by.
  List<Peer> _everyone() => [
        for (final p in people())
          if (p.key != null && p.id.length == 32) p,
      ];

  /// Those of them it may say it is here to and link with now: all, or this account's own devices alone while the
  /// person chose Invisible.
  List<Peer> _people() => _invisible ? [for (final p in _everyone()) if (p.id == me) p] : _everyone();

  Peer? _person(String id) => _people().where((p) => p.id == id).firstOrNull;

  /// Whether [address] is one the route hears from, connects to and takes connections from: a private one on a network
  /// this device has an address on (or, for a test, whatever it says).
  bool _allowed(String address) {
    final by = _allowedBy;
    if (by != null) return by(address);
    return isLanAddress(address) && _addresses.any((mine) => sameNet(mine, address));
  }

  // --- starting and stopping -------------------------------------------------------------------------------------------

  @override
  Future<void> start() async {
    _wanted = true;
    await _settle();
  }

  @override
  Future<void> stop() async {
    _wanted = false;
    await _settle();
  }

  /// The app put away or in use: a phone's route closes everything while it is away, and opens again as it comes back.
  void setAway(bool away) {
    if (_away == away) return;
    _away = away;
    unawaited(_settle());
  }

  /// How the person chose to be shown (Me.presenceMode). Into Invisible or out of it, a route that is running starts
  /// over under a new name and a new door: what its friends' devices knew it by is gone from the network, every link
  /// closed, and from then on only its own account's devices can tell whose it is (or, shown again, its friends' too).
  void setMode(String mode) {
    final invisible = mode == 'invisible';
    if (_invisible == invisible) return;
    _invisible = invisible;
    _bump();
    if (_air != null || _opening) unawaited(_reopen());
  }

  /// The network may be another than it was (the app came back, Wi-Fi changed). On other networks than before, the
  /// route starts over under a new name, so it is not known on one network by what it was on the last; on the same,
  /// it says it is here at once.
  void networkChanged() => unawaited(_networkChanged());

  Future<void> _networkChanged() async {
    if (_air == null) return;
    final session = _session;
    List<String> now;
    try {
      now = await ground.addresses();
    } catch (_) {
      now = const [];
    }
    if (session != _session || _air == null) return;
    if (!setEquals(now.toSet(), _addresses.toSet())) return _reopen();
    await beat();
  }

  /// Whom it links with changed (someone became a friend, or is one no longer): links to anyone no longer among them
  /// are closed, and it says it is here again.
  void refresh() {
    final ids = {for (final p in _people()) p.id};
    for (final l in _links.where((l) => !ids.contains(l.peer)).toList()) {
      _close(l);
    }
    _seen.removeWhere((_, s) => !ids.contains(s.peer));
    _keys.removeWhere((id, _) => !ids.contains(id));
    _accounts.removeWhere((id, _) => !ids.contains(id));
    // Someone it named nobody for before may be one of its people now.
    _strange.clear();
    _bump();
    unawaited(beat());
  }

  bool get _shouldRun => _wanted && !(_away && policy.sleepsAway);

  /// Opens or closes everything to match what is wanted now.
  Future<void> _settle() async {
    if (_shouldRun) {
      if (_air == null && !_opening) await _open();
    } else {
      await _shut();
      _set(_wanted ? CarrierState.connecting : CarrierState.off, null);
    }
  }

  /// Closes everything and opens it again under a new name, where the route is still wanted.
  Future<void> _reopen() async {
    await _shut();
    await _settle();
  }

  Future<void> _open() async {
    _opening = true;
    _againTimer?.cancel();
    _set(CarrierState.connecting, null);
    final session = _session;
    LanDoor? door;
    LanAir? air;
    try {
      _run = _bytes(LanBeacon.instanceLength);
      _noise = _bytes(32);
      _runName = NetCrypto.hex(_run);
      _addresses = await ground.addresses();
      door = await ground.door(_came);
      air = await ground.air(_heard, lost: () => _lost(session));
    } catch (e) {
      await door?.close().catchError((Object _) {});
      _opening = false;
      if (!_shouldRun || session != _session) return _set(_wanted ? CarrierState.connecting : CarrierState.off, null);
      _set(CarrierState.down, 'The local network can\'t be used on this device now ($e).');
      // Tried again in a while: a port another program holds, or no network yet.
      _againTimer = Timer(policy.redialAfter * 2, () => unawaited(_settle()));
      return;
    }
    _opening = false;
    // Closed, or wanted otherwise, while it was opening (stopped, the person's mode changed): this one is let go, and
    // what is wanted now is settled again.
    if (!_shouldRun || session != _session) {
      await door.close().catchError((Object _) {});
      await air.close().catchError((Object _) {});
      if (session != _session) unawaited(_settle());
      return;
    }
    _door = door;
    _air = air;
    _openedAt = _now();
    _beaconBudget = _Bucket(beaconsAtOnce, beaconsASecond.toDouble(), _now());
    _knownBudget = _Bucket(knownAtOnce, knownASecond.toDouble(), _now());
    _lookBudget = _Bucket(runsAtOnce, runsASecond.toDouble(), _now());
    _dialBudget = _Bucket(dialsAtOnce, dialsASecond, _now());
    _set(CarrierState.up, null);
    _beatTimer = Timer.periodic(policy.beatEvery, (_) => unawaited(beat()));
    _sweepTimer = Timer.periodic(policy.sweepEvery, (_) => sweep());
    unawaited(beat());
  }

  /// The air stopped hearing by itself, under the opening [session]: everything is closed and opened again.
  void _lost(int session) {
    if (session != _session || _air == null) return;
    unawaited(_reopen());
  }

  Future<void> _shut() async {
    _session++;
    _opening = false;
    _beatTimer?.cancel();
    _sweepTimer?.cancel();
    _againTimer?.cancel();
    _beatTimer = _sweepTimer = _againTimer = null;
    for (final t in _yields.values) {
      t.cancel();
    }
    _yields.clear();
    final air = _air, door = _door;
    _air = null;
    _door = null;
    for (final l in _links.toList()) {
      _close(l);
    }
    // And every connection that had not yet proved whose it was: nothing more is said on one, or taken from it.
    for (final w in _proving.keys.toList()) {
      unawaited(w.close().catchError((Object _) {}));
    }
    _proving.clear();
    final had = _seen.isNotEmpty;
    _seen.clear();
    _strange.clear();
    _failed.clear();
    _dialled.clear();
    _knocks.clear();
    _lookFrom.clear();
    _accounts.clear();
    _addresses = const [];
    await air?.close().catchError((Object _) {});
    await door?.close().catchError((Object _) {});
    if (had) _bump();
  }

  void _set(CarrierState next, String? why) {
    problem = why;
    if (state.value != next) state.value = next;
  }

  void _bump() => changed.value++;

  // --- saying it is here, and hearing who is --------------------------------------------------------------------------

  /// Says a beacon now on each network this device is on (and every [LanPolicy.beatEvery] by itself): a mark for each
  /// person, noise beside them.
  Future<void> beat() async {
    final air = _air, door = _door, session = _session;
    if (air == null || door == null) return;
    List<String> addresses;
    try {
      addresses = await ground.addresses();
    } catch (_) {
      addresses = const [];
    }
    if (session != _session) return;
    _addresses = addresses;
    if (addresses.isEmpty) {
      return _set(CarrierState.down, 'This device is on no Wi-Fi or wired network of the kind this route uses now.');
    }
    final bucket = LanWords.bucketOf(_now().millisecondsSinceEpoch);
    final everyone = _everyone();
    final size = LanBeacon.sizeFor(everyone.length);
    var named = _people();
    // More people than a beacon holds: one lot of them for each ten minutes, the same for all of it.
    if (named.length > LanBeacon.mostMarks) {
      final sorted = [...named]..sort((a, b) => a.id.compareTo(b.id));
      final from = (bucket * LanBeacon.mostMarks) % sorted.length;
      named = [for (var i = 0; i < LanBeacon.mostMarks; i++) sorted[(from + i) % sorted.length]];
    }
    var said = false;
    for (final address in addresses) {
      final marks = <Uint8List>[];
      for (final p in named) {
        final key = _lanKey(p);
        final mark = key == null ? null : LanWords.mark(key, from: me, to: p.id, bucket: bucket, instance: _run, port: door.port, address: address);
        if (mark != null) marks.add(mark);
      }
      // As many marks whoever they are for: noise in the place of what is not said, the same for its ten minutes.
      for (var slot = 0; marks.length < size; slot++) {
        marks.add(LanWords.noise(_noise, bucket: bucket, address: address, slot: slot));
      }
      marks.sort(_byBytes);
      final beacon = LanBeacon(instance: _run, port: door.port, bucket: bucket, marks: marks).encode();
      bool ok;
      try {
        ok = await air.say(address, beacon);
      } catch (_) {
        ok = false;
      }
      if (session != _session) return;
      said = said || ok;
    }
    // Said nowhere: no network just now, or the system keeps the app off it (macOS's Local Network switch). Said so,
    // and tried again with the next beacon. Not while a link is open, though: a device that is heard and connected to
    // carries, whatever became of its own beacon.
    final carrying = said || _links.isNotEmpty;
    _set(carrying ? CarrierState.up : CarrierState.down, carrying ? null : 'Nothing can be said on the local network now: this device is on none, or its system settings keep Uplink off the local network.');
  }

  static int _byBytes(Uint8List a, Uint8List b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }

  /// A beacon came from [address].
  void _heard(Uint8List bytes, String address) {
    if (_air == null || !_allowed(address)) return;
    final now = _now();
    // Whose run it says it is, before anything else is done with it.
    final run = LanBeacon.runOf(bytes);
    if (run == null || run == _runName) return;
    final bucketNow = LanWords.bucketOf(now.millisecondsSinceEpoch);
    LanBeacon? b;
    Set<String>? said;

    // A run known already at this address: one mark to look for, for each of the people whose it is, and a count of
    // its own for those, so what strangers say takes nothing from hearing a device that is here.
    final known = [
      for (final s in _seen.values)
        if (s.run == run && s.address == address) s,
    ];
    if (known.isNotEmpty) {
      if (!_knownBudget.take(now)) {
        droppedBeacons++;
        return;
      }
      b = LanBeacon.decode(bytes);
      if (b == null || (b.bucket - bucketNow).abs() > 1) return;
      said = {for (final m in b.marks) NetCrypto.hex(m)};
      var still = false;
      for (final s in known) {
        final p = _person(s.peer);
        final key = p == null ? null : _lanKey(p);
        final mark = key == null ? null : LanWords.mark(key, from: s.peer, to: me, bucket: b.bucket, instance: b.instance, port: b.port, address: address);
        if (mark == null || !said.contains(NetCrypto.hex(mark))) continue;
        still = true;
        s
          ..port = b.port
          ..at = now;
        _meet(s.peer, run);
      }
      if (still) return;
    }

    // One not seen before. So many at once and a second, and no more, before anything is done with it.
    if (!_beaconBudget.take(now)) {
      droppedBeacons++;
      return;
    }
    b ??= LanBeacon.decode(bytes);
    if (b == null || (b.bucket - bucketNow).abs() > 1) return;
    // Looked at once for each ten minutes, port and address, within what may be looked at.
    final tag = '$run:${b.bucket}:${b.port}:$address';
    if (_strange.contains(tag)) return;
    if (!_lookFrom.putIfAbsent(address, () => _Bucket(runsFromOne, runsFromOne / 60, now)).take(now) || !_lookBudget.take(now)) return;
    said ??= {for (final m in b.marks) NetCrypto.hex(m)};
    String? who;
    for (final p in _people()) {
      // Not one it knows this run as already (looked for above).
      if (known.any((s) => s.peer == p.id)) continue;
      final key = _lanKey(p);
      final mark = key == null ? null : LanWords.mark(key, from: p.id, to: me, bucket: b.bucket, instance: b.instance, port: b.port, address: address);
      if (mark != null && said.contains(NetCrypto.hex(mark))) {
        who = p.id;
        break;
      }
    }
    if (who == null) {
      _strange.add(tag);
      while (_strange.length > mostStrange) {
        _strange.remove(_strange.first);
      }
      return;
    }
    final key = _keyOf(who, run);
    final had = _seen[key];
    // Heard elsewhere a moment ago, or linked: where it is said to be now is not believed over that. A device that
    // truly moved is heard at its new address once the old one has gone quiet.
    if (had != null && had.address != address && (now.difference(had.at) <= policy.seenFor || _linkTo(who, run) != null)) return;
    if (had == null) {
      // An account's devices are a few: beyond so many, the one heard longest ago that no link is open to gives way.
      final theirs = [
        for (final s in _seen.values)
          if (s.peer == who && _linkTo(s.peer, s.run) == null) s,
      ]..sort((x, y) => x.at.compareTo(y.at));
      for (var over = _seen.values.where((s) => s.peer == who).length - mostSeenOf + 1, i = 0; over > 0 && i < theirs.length; over--, i++) {
        final gone = _keyOf(theirs[i].peer, theirs[i].run);
        _seen.remove(gone);
        _yields.remove(gone)?.cancel();
      }
    }
    _seen[key] = _Seen(who, run, address, b.port, now);
    _bump();
    _meet(who, run);
  }

  /// Links with [peer]'s device whose run is [run], heard just now, where no link is open or being made: at once where
  /// this run's name is the lesser, else once the other has had [LanPolicy.yieldFor] to connect first.
  void _meet(String peer, String run) {
    final key = _keyOf(peer, run);
    if (_linkTo(peer, run) != null || _dials.containsKey(key) || _yields.containsKey(key)) return;
    if (_runName.compareTo(run) < 0) {
      unawaited(_dial(peer, run));
      return;
    }
    _yields[key] = Timer(policy.yieldFor, () {
      _yields.remove(key);
      if (_air != null && _linkTo(peer, run) == null) unawaited(_dial(peer, run));
    });
  }

  // --- links ----------------------------------------------------------------------------------------------------------

  /// The newest link open to [peer]'s device whose run is [run]; null where there is none.
  _Link? _linkTo(String peer, String run) => _links.where((l) => l.peer == peer && l.run == run).lastOrNull;

  /// The links open to [peer]'s devices, one for each device.
  List<_Link> _linksOf(String peer) {
    final byRun = <String, _Link>{};
    for (final l in _links) {
      if (l.peer == peer) byRun[l.run] = l;
    }
    return byRun.values.toList();
  }

  /// The devices linked now, as Settings › Routes lists them; the accounts they are; and how many of the people's
  /// devices are known to be on the network: those heard lately and those linked (one that connected here may never
  /// have been heard).
  List<LanLinked> get links => [
        for (final l in {for (final l in _links) _keyOf(l.peer, l.run): l}.values) LanLinked(peer: l.peer, address: l.wire.address),
      ];
  Set<String> get linkedAccounts => {for (final l in _links) l.peer};
  int get seen => {..._seen.keys, for (final l in _links) _keyOf(l.peer, l.run)}.length;

  /// Connects to [peer]'s device whose run is [run], as it was last heard, and proves each end to the other. Whether a
  /// link to it is open after. One already being made is the one waited for.
  Future<bool> _dial(String peer, String run) {
    final key = _keyOf(peer, run);
    final under = _dials[key];
    if (under != null) return under;
    if (_linkTo(peer, run) != null) return Future.value(true);
    final seen = _seen[key];
    final now = _now();
    if (seen == null || _air == null || _dials.length >= mostDialing) return Future.value(false);
    final failed = _failed[key];
    if (failed != null && now.difference(failed) < policy.redialAfter) return Future.value(false);
    // So many a minute to one address, whatever it is said to be the door of.
    final to = _dialled.putIfAbsent(seen.address, () => [])..removeWhere((t) => now.difference(t) > const Duration(minutes: 1));
    // And so many in all, wherever to: a device is never sent knocking on doors all over the network.
    if (to.length >= dialsAMinuteTo || !_allowed(seen.address) || !_dialBudget.take(now)) return Future.value(false);
    to.add(now);
    // (Not `=> _dials.remove(key)`: that hands whenComplete the very future it is making, to wait for.)
    final dial = _connect(seen, key).whenComplete(() {
      _dials.remove(key);
    });
    _dials[key] = dial;
    return dial;
  }

  Future<bool> _connect(_Seen seen, String key) async {
    final session = _session;
    // Still the same opening, and still someone it links with (not since gone Invisible, say).
    Uint8List? live() {
      if (session != _session || _air == null) return null;
      final p = _person(seen.peer);
      return p == null ? null : _lanKey(p);
    }

    LanWire? wire;
    try {
      wire = await ground.dial(seen.address, seen.port, timeout: policy.dialFor);
      _proving[wire] = seen.address;
      // Looked at again before a word is said: the connection took a moment to make.
      var lanKey = live();
      if (lanKey == null) throw const _Refused();
      final frames = StreamIterator(wire.frames);
      final listener = NetCrypto.unhex(seen.run);
      final nonce = _bytes(16);
      final bucket = LanWords.bucketOf(_now().millisecondsSinceEpoch);
      wire.send(Uint8List.fromList([1, ..._run, ...nonce, (bucket >> 24) & 0xff, (bucket >> 16) & 0xff, (bucket >> 8) & 0xff, bucket & 0xff, ...LanWords.knock(lanKey, from: me, to: seen.peer, dialer: _run, listener: listener, nonce: nonce, bucket: bucket)]));
      if (!await frames.moveNext().timeout(policy.proveFor)) throw const _Refused();
      final answer = frames.current;
      if (answer.length != 1 + 16 + 32 || answer[0] != 2) throw const _Refused();
      // And again before its proof.
      lanKey = live();
      if (lanKey == null) throw const _Refused();
      final transcript = LanWords.transcript(dialerAccount: me, listenerAccount: seen.peer, dialer: _run, listener: listener, dialerNonce: nonce, listenerNonce: answer.sublist(1, 17));
      if (!LanWords.same(answer.sublist(17), LanWords.proof(lanKey, transcript, dialing: false))) throw const _Refused();
      wire.send(Uint8List.fromList([3, ...LanWords.proof(lanKey, transcript, dialing: true)]));
      _proving.remove(wire);
      final link = _Link(seen.peer, seen.run, wire, LanWords.sealKey(lanKey, transcript, dialing: true), LanWords.sealKey(lanKey, transcript, dialing: false), _now());
      if (!_adopt(link)) return false;
      unawaited(_listen(link, frames));
      return true;
    } catch (_) {
      if (session == _session) _failed[key] = _now();
      if (wire != null) {
        _proving.remove(wire);
        unawaited(wire.close().catchError((Object _) {}));
      }
      return false;
    }
  }

  /// Someone connected to this device's door.
  void _came(LanWire wire) => unawaited(_take(wire).catchError((Object _) {}));

  Future<void> _take(LanWire wire) async {
    final from = wire.address;
    final session = _session;
    final now = _now();
    // Not from an address it takes anything from, or the route is closed: closed, and nothing kept of it.
    if (_air == null || !_allowed(from)) {
      await wire.close().catchError((Object _) {});
      return;
    }
    final knocks = _knocks.putIfAbsent(from, () => [])..removeWhere((t) => now.difference(t) > const Duration(minutes: 1));
    // From where a device it recognised was heard lately, a connection is always taken: strangers who hold connections
    // open and say nothing can't keep its people out. The rest share what room there is.
    final recognised = _seen.values.any((s) => s.address == from && now.difference(s.at) <= policy.seenFor);
    final others = _proving.values.where((a) => !_seen.values.any((s) => s.address == a)).length;
    final fromHere = _proving.values.where((a) => a == from).length;
    if (knocks.length >= knocksAMinute || fromHere >= mostProvingFrom || (!recognised && others >= mostProving)) {
      if (knocks.isEmpty) _knocks.remove(from);
      await wire.close().catchError((Object _) {});
      return;
    }
    knocks.add(now);
    _proving[wire] = from;
    try {
      final frames = StreamIterator(wire.frames);
      if (!await frames.moveNext().timeout(policy.knockFor)) throw const _Refused();
      final knock = frames.current;
      if (session != _session || _air == null) throw const _Refused();
      if (knock.length != 1 + LanBeacon.instanceLength + 16 + 4 + LanWords.knockLength || knock[0] != 1) throw const _Refused();
      final dialer = knock.sublist(1, 9), nonce = knock.sublist(9, 25);
      final bucket = ByteData.sublistView(knock, 25, 29).getUint32(0);
      final said = knock.sublist(29);
      final run = NetCrypto.hex(dialer);
      if (run == _runName || (bucket - LanWords.bucketOf(_now().millisecondsSinceEpoch)).abs() > 1) throw const _Refused();
      // Whose device it is: the one of the people whose key makes this knock, to this very run. Nobody's: closed
      // without a word.
      Peer? peer;
      Uint8List? key;
      for (final p in _people()) {
        final k = _lanKey(p);
        if (k == null) continue;
        if (LanWords.same(said, LanWords.knock(k, from: p.id, to: me, dialer: dialer, listener: _run, nonce: nonce, bucket: bucket))) {
          peer = p;
          key = k;
          break;
        }
      }
      if (peer == null || key == null) throw const _Refused();
      final mine = _bytes(16);
      final transcript = LanWords.transcript(dialerAccount: peer.id, listenerAccount: me, dialer: dialer, listener: _run, dialerNonce: nonce, listenerNonce: mine);
      wire.send(Uint8List.fromList([2, ...mine, ...LanWords.proof(key, transcript, dialing: false)]));
      if (!await frames.moveNext().timeout(policy.proveFor)) throw const _Refused();
      final proof = frames.current;
      if (session != _session || _air == null || _person(peer.id) == null) throw const _Refused();
      if (proof.length != 1 + 32 || proof[0] != 3 || !LanWords.same(proof.sublist(1), LanWords.proof(key, transcript, dialing: true))) throw const _Refused();
      _proving.remove(wire);
      final link = _Link(peer.id, run, wire, LanWords.sealKey(key, transcript, dialing: false), LanWords.sealKey(key, transcript, dialing: true), _now());
      if (!_adopt(link)) return;
      unawaited(_listen(link, frames));
    } catch (_) {
      _proving.remove(wire);
      await wire.close().catchError((Object _) {});
    }
  }

  Uint8List _bytes(int n) => Uint8List.fromList(List.generate(n, (_) => _random.nextInt(256)));

  /// Holds [link], proved, where there is room: the oldest link to the same run of the same account is let go for a
  /// third, the account's oldest for its ninth, and with as many links as the route holds in all, this one is not
  /// taken. Never another account's link for this account's: whose run a name is, is the account that proved it.
  bool _adopt(_Link link) {
    final same = _links.where((l) => l.peer == link.peer && l.run == link.run).toList();
    while (same.length >= mostLines) {
      _close(same.removeAt(0));
    }
    final theirs = _links.where((l) => l.peer == link.peer).toList();
    while (theirs.length >= mostPerAccount) {
      _close(theirs.removeAt(0));
    }
    if (_links.length >= mostLinks) {
      link.open = false;
      unawaited(link.wire.close().catchError((Object _) {}));
      return false;
    }
    _links.add(link);
    _failed.remove(_keyOf(link.peer, link.run));
    // Linked, it carries: it is not down, whatever its last beacon came to.
    if (_air != null && state.value == CarrierState.down) _set(CarrierState.up, null);
    _bump();
    return true;
  }

  /// Takes what [link] brings until it closes: each frame within what a link may say, opened under the link's key and
  /// counted, a packet handed on as whose the link proved to be.
  Future<void> _listen(_Link link, StreamIterator<Uint8List> frames) async {
    try {
      while (await frames.moveNext()) {
        final f = frames.current;
        final now = _now();
        // More than a link may say, whatever it is saying: closed, before anything is opened.
        if (!link.frames.take(now)) {
          dropped++;
          break;
        }
        if (f.isEmpty || f[0] != 4) break;
        final clear = NetCrypto.open(link.opens, Uint8List.sublistView(f, 1));
        if (clear == null || clear.length < 9) break;
        final d = ByteData.sublistView(clear);
        // Each frame once and in order: one said again, or out of turn, ends the link.
        if (d.getUint32(0) != link.heardHigh || d.getUint32(4) != link.heardLow) break;
        link.countHeard();
        link.heardAt = now;
        if (clear[8] != 1) continue;
        if (!link.packets.take(now) || !_accounts.putIfAbsent(link.peer, () => _Bucket(accountBurst, accountPerSecond.toDouble(), now)).take(now)) {
          dropped++;
          continue;
        }
        if (!_arrived.isClosed) _arrived.add(Arrived(routeId, Uint8List.sublistView(clear, 9), from: link.peer, line: link));
      }
    } catch (_) {
    } finally {
      _close(link);
    }
  }

  void _close(_Link link) {
    final had = _links.remove(link);
    link.open = false;
    unawaited(link.wire.close().catchError((Object _) {}));
    if (had) _bump();
  }

  /// Forgets devices not heard from in [LanPolicy.seenFor] (but ones a link is open to), says a word on links with
  /// nothing said lately, closes those nothing has been heard on, and lets go of what it kept count by for addresses
  /// that are gone. With no link open, a route that has run [LanPolicy.rerunAfter] starts over under a new name. By
  /// itself every [LanPolicy.sweepEvery].
  @visibleForTesting
  void sweep() {
    final now = _now();
    final before = _seen.length;
    // Links first: a device whose link has just been closed for silence is forgotten in the same turn.
    for (final l in _links.toList()) {
      if (now.difference(l.heardAt) > policy.quietFor) {
        _close(l);
      } else if (now.difference(l.saidAt) > policy.pingEvery) {
        l.say(0, const [], now);
      }
    }
    _seen.removeWhere((_, s) => now.difference(s.at) > policy.seenFor && _linkTo(s.peer, s.run) == null);
    _failed.removeWhere((_, at) => now.difference(at) > policy.redialAfter);
    for (final m in [_knocks, _dialled]) {
      m.removeWhere((_, times) => (times..removeWhere((t) => now.difference(t) > const Duration(minutes: 1))).isEmpty);
    }
    _lookFrom.removeWhere((_, b) => b.full(now));
    if (_seen.length != before) _bump();
    if (_air != null && _links.isEmpty && _dials.isEmpty && now.difference(_openedAt) > policy.rerunAfter) unawaited(_reopen());
  }

  // --- carrying -------------------------------------------------------------------------------------------------------

  /// A link is open to one of their devices, or one of theirs was heard on this network lately.
  @override
  bool reaches(Peer peer) {
    if (_air == null) return false;
    if (_links.any((l) => l.peer == peer.id)) return true;
    final now = _now();
    return _seen.values.any((s) => s.peer == peer.id && now.difference(s.at) <= policy.seenFor);
  }

  @override
  Future<Handed> send(Peer peer, Uint8List packet) async {
    if (packet.length > maxPacket) throw CarrierError('too long for the local network');
    if (_air == null) throw CarrierError('the local network route is not running');
    var links = _linksOf(peer.id);
    if (links.isEmpty) {
      final runs = [for (final s in _seen.values) if (s.peer == peer.id) s.run];
      if (runs.isEmpty) throw CarrierError('they are not on this network now');
      await Future.wait([for (final r in runs) _dial(peer.id, r)]);
      links = _linksOf(peer.id);
      if (links.isEmpty) throw CarrierError('their device on this network could not be linked with');
    }
    return _put(links, packet);
  }

  Handed _put(List<_Link> links, Uint8List packet) {
    final now = _now();
    var took = false;
    for (final l in links) {
      if (l.say(1, packet, now)) took = true;
    }
    if (!took) throw CarrierError('no link on this network took it');
    return Handed.passed;
  }

  @override
  bool linked(Peer peer) => _links.any((l) => l.peer == peer.id);

  @override
  bool get linkedToSomeone => _links.any((l) => l.peer != me);

  @override
  Future<Handed> sendLinked(Peer peer, Uint8List packet) async {
    if (packet.length > maxPacket) throw CarrierError('too long for the local network');
    final links = _linksOf(peer.id);
    if (links.isEmpty) throw CarrierError('no link to them is open on this network');
    return _put(links, packet);
  }

  @override
  Future<Handed> sendOn(Peer peer, Object? line, Uint8List packet) async {
    if (packet.length > maxPacket) throw CarrierError('too long for the local network');
    if (line is _Link && line.open && line.peer == peer.id && _links.contains(line)) return _put([line], packet);
    return sendLinked(peer, packet);
  }

  /// Closes everything, for good: the app is closing, or a test is over.
  Future<void> dispose() async {
    _wanted = false;
    await _shut();
    _set(CarrierState.off, null);
    if (!_arrived.isClosed) await _arrived.close();
  }
}

/// A device heard on the network: whose it is, its run, where, and when it was last heard.
class _Seen {
  _Seen(this.peer, this.run, this.address, this.port, this.at);
  final String peer, run, address;
  int port;
  DateTime at;
}

/// So many at once, and so many more a second after: what may still be taken now.
class _Bucket {
  _Bucket(this.most, this.perSecond, DateTime now)
      : _left = most.toDouble(),
        _at = now;
  final int most;
  final double perSecond;
  double _left;
  DateTime _at;

  void _fill(DateTime now) {
    final gone = now.difference(_at).inMilliseconds;
    if (gone <= 0) return;
    _left = min(most.toDouble(), _left + gone * perSecond / 1000);
    _at = now;
  }

  /// Takes one, where one is left.
  bool take(DateTime now) {
    _fill(now);
    if (_left < 1) return false;
    _left -= 1;
    return true;
  }

  /// Whether nothing has been taken that is not made up for by now.
  bool full(DateTime now) {
    _fill(now);
    return _left >= most;
  }
}

/// A link to one device, proved: whose it is, the run of the route at its other end, and the keys and counts of what
/// goes each way.
class _Link {
  _Link(this.peer, this.run, this.wire, this.seals, this.opens, DateTime now)
      : heardAt = now,
        saidAt = now,
        packets = _Bucket(LanCarrier.lineBurst, LanCarrier.linePerSecond.toDouble(), now),
        frames = _Bucket(LanCarrier.frameBurst, LanCarrier.framePerSecond.toDouble(), now);
  final String peer, run;
  final LanWire wire;
  final Uint8List seals, opens;
  bool open = true;
  DateTime heardAt, saidAt;

  /// What it may still bring now: packets, and frames of any kind.
  final _Bucket packets, frames;

  // The count of what was said and heard, each as two halves of 32 bits (a browser's numbers hold no more whole).
  int _saidHigh = 0, _saidLow = 0;
  int heardHigh = 0, heardLow = 0;

  void countHeard() {
    heardLow++;
    if (heardLow > 0xffffffff) {
      heardLow = 0;
      heardHigh++;
    }
  }

  /// Says [body] of [kind] (0 a word to keep the link, 1 a packet), sealed and counted. Whether it was handed to the
  /// wire.
  bool say(int kind, List<int> body, DateTime now) {
    if (!open) return false;
    final clear = Uint8List(9 + body.length);
    ByteData.sublistView(clear)
      ..setUint32(0, _saidHigh)
      ..setUint32(4, _saidLow);
    clear[8] = kind;
    clear.setRange(9, clear.length, body);
    _saidLow++;
    if (_saidLow > 0xffffffff) {
      _saidLow = 0;
      _saidHigh++;
    }
    wire.send(Uint8List.fromList([4, ...NetCrypto.seal(seals, clear)]));
    saidAt = now;
    return true;
  }
}

/// A connection that didn't prove whose it was, or said something that is no part of proving.
class _Refused implements Exception {
  const _Refused();
}
