import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'crypto.dart';
import 'fast_gcm.dart';

/// Forward secrecy for what goes between friends, and between an account's own devices (GMFB-26, from the Uplink gap
/// review: "Forward secrecy and key rotation for friends and circles"). docs/FORWARD_SECRECY.md is the whole design;
/// this is its working part.
///
/// **Why it is needed.** Until now a packet to a friend was sealed with the pair's key (NetCrypto.netKey), which comes
/// from the two accounts' long-term keys alone, and a copy to the account's own devices with a key from the account's
/// words (Me.mineKey). Whoever later learns the words, or takes a device, and has kept the packets (the relay, or
/// anyone on the way) could open every one of them, back to the first.
///
/// **What is done instead.** Each device makes a key pair of its own (a "prekey") that is never written into the
/// account's backup and can't be worked out from the account's words. It makes a new one every [rotateEvery], and
/// deletes each one's private half [keepFor] after making it. It offers its newest to everyone it talks to, inside the
/// sealed envelopes it sends (Envelope.fs), so no server is needed and a relay that knows nothing of this carries it.
///
/// A packet to someone whose devices have offered a prekey is sealed under a fresh key pair made for that packet alone
/// and forgotten once it is sealed: for each of their devices, ECDH of the one-off key with that device's prekey,
/// through HKDF salted with the pair's key, wraps a random key the envelope is sealed with. So opening it needs a
/// prekey's private half (deleted after [keepFor]) or the one-off key's (never kept): the account's words and the
/// long-term key are not enough. The pair's key in the salt is what says who sent it, as before.
///
/// One account is the same identity on several devices, and the relay hands a packet for an id to every device of
/// it that is connected, or keeps it for whichever comes first. So a packet carries one wrapped key per device of the
/// account that has offered a prekey, and any of them can open it; a device's own copies to its siblings (GMFB-21)
/// are sealed the same way, to the siblings' prekeys.
///
/// Wire layout of a forward-secret packet's last field (Packet flag 4):
///
///     [1: how many devices, n][33: the one-off public key]
///     n × [16: the device's name][4: its prekey's name][60: the content key, sealed: 12 nonce, 32, 16 tag]
///     [the envelope, sealed with the content key: 12 nonce, the bytes, 16 tag]
///
/// Each entry's key: HKDF-SHA256(salt: the pair's key, ikm: ECDH(one-off, prekey), info: "ghost fs v1 wrap" | from |
/// to | device | prekey | one-off public). The envelope is sealed with AES-256-GCM under the content key, with every
/// byte before it, from and to as its additional data, so no entry can be swapped for another's.
class ForwardSecrecy {
  ForwardSecrecy({required this.device, required FsStore secrets, required FsStore plain, DateTime Function()? now})
      : _secrets = secrets,
        _plain = plain,
        _now = now ?? DateTime.now {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(device)) throw ArgumentError('a device is named by 32 hex digits');
  }

  /// This device's name among its identity's devices (HubCarrier.device): 32 hex digits.
  final String device;
  final FsStore _secrets;
  final FsStore _plain;
  final DateTime Function() _now;

  /// How often a device makes a new prekey.
  static const rotateEvery = Duration(days: 1);

  /// How long after a prekey is made others still seal to it, where they have heard nothing newer. Past this a
  /// packet to that device goes sealed the old way (and its answer brings the newer prekey).
  static const useFor = Duration(days: 7);

  /// How long after it is made a prekey's private half is kept: [useFor], then the relay's longest hold (7 days,
  /// relay/lib/hub.dart holdFor) and a day more. Deleted after; what was sealed to it can't be opened by anyone.
  static const keepFor = Duration(days: 15);

  /// The most devices of one identity kept for it; the ones heard from longest ago go first.
  static const mostDevices = 8;

  /// The most one-off keys remembered, to tell a packet seen before ([open]'s replay).
  static const mostSeen = 5000;

  static const secretsName = 'fs_prekeys';
  static const peersName = 'fs_peers';
  static const seenName = 'fs_seen';
  static const oldName = 'fs_old';
  static const passedName = 'fs_passed';

  /// Packets this device passed on to its own name (a tag of each), kept across restarts: the relay may hand one back
  /// to the device that passed it on, which must not pass it on again (second review, A6). The newest [mostPassed].
  final LinkedHashMap<String, int> _passed = LinkedHashMap();
  static const mostPassed = 1000;

  /// How many times one packet is put back on this account's name when the relay hands it back to the device that
  /// passed it on (third review, item 2).
  static const mostPassTries = 3;

  /// How long a packet sealed the old way without a prekey (a build from before, or a device whose forward secrecy
  /// couldn't load) from an id is taken to mean that id has such a device: everything to it is sealed the old way
  /// too, so that device can read it (GMFB-26 review, finding 2).
  static const oldDeviceFor = Duration(days: 7);

  /// Whether sealing and opening run on an isolate of their own, off the one that draws the screens (finding 9).
  static bool offThread = true;

  static final _wrapInfo = utf8.encode('ghost fs v1 wrap');
  static final _wrapAad = Uint8List.fromList(utf8.encode('ghost fs v1 key'));
  static final _bodyAad = utf8.encode('ghost fs v1');
  static const _entry = 16 + 4 + 60;

  final List<_Prekey> _mine = [];
  final Map<String, Map<String, FsBundle>> _peers = {};

  /// One-off keys of packets opened (a tag of each), by the prekey they came under: dropped with it.
  final LinkedHashMap<String, String> _seen = LinkedHashMap();

  /// When a packet sealed the old way, with no prekey in it, last came from each id (ms).
  final Map<String, Map<String, int>> _old = {};
  bool _loaded = false;
  Future<void>? _refreshing;
  Timer? _seenTimer;

  bool get loaded => _loaded;

  /// [load], answering whether it worked instead of throwing: the app tries again until it does (an iPhone's Keychain
  /// can't be read before its first unlock).
  Future<bool> tryLoad() async {
    if (_loaded) return true;
    try {
      await load();
      return true;
    } catch (_) {
      _loaded = false;
      return false;
    }
  }

  /// Reads what is kept. Throws where the secret store can't be read: nothing is sealed for forward secrecy until it
  /// can be, rather than make keys it can't keep.
  Future<void> load() async {
    final kept = await _secrets.read(secretsName);
    _mine.clear();
    if (kept != null && kept.isNotEmpty) {
      for (final j in jsonDecode(kept) as List) {
        final p = _Prekey.fromJson(j);
        if (p != null) _mine.add(p);
      }
    }
    _peers.clear();
    try {
      final j = jsonDecode(await _plain.read(peersName) ?? '{}') as Map;
      for (final e in j.entries) {
        final devices = <String, FsBundle>{};
        if (e.value is Map) {
          for (final b in (e.value as Map).values) {
            final bundle = FsBundle.fromJson(b);
            if (bundle != null) devices[bundle.device] = bundle;
          }
        }
        if (devices.isNotEmpty) _peers['${e.key}'] = devices;
      }
    } catch (_) {}
    _seen.clear();
    try {
      final j = jsonDecode(await _plain.read(seenName) ?? '[]') as List;
      for (final x in j) {
        if (x is List && x.length == 2 && x[0] is String && x[1] is String) _seen[x[0] as String] = x[1] as String;
      }
    } catch (_) {}
    _passed.clear();
    try {
      final j = jsonDecode(await _plain.read(passedName) ?? '{}');
      if (j is List) {
        for (final t in j.whereType<String>()) {
          _passed[t] = 1;
        }
      } else if (j is Map) {
        for (final e in j.entries) {
          if (e.value is int) _passed['${e.key}'] = e.value as int;
        }
      }
    } catch (_) {}
    _old.clear();
    try {
      for (final e in (jsonDecode(await _plain.read(oldName) ?? '{}') as Map).entries) {
        // By id, then device ('' for one that can't say which: a build from before); an older file kept by id alone.
        if (e.value is int) _old['${e.key}'] = {'': e.value as int};
        if (e.value is Map) _old['${e.key}'] = {for (final d in (e.value as Map).entries) if (d.value is int) '${d.key}': d.value as int};
      }
    } catch (_) {}
    _loaded = true;
    await refresh();
  }

  /// Deletes prekeys past [keepFor] and makes a new one where the newest is [rotateEvery] old. The new one is kept
  /// before it is offered to anyone.
  Future<void> refresh() {
    final running = _refreshing;
    if (running != null) return running;
    final f = _refresh();
    _refreshing = f;
    return f.whenComplete(() => _refreshing = null);
  }

  Future<void> _refresh() async {
    if (!_loaded) return;
    final now = _now().millisecondsSinceEpoch;
    final gone = _mine.where((p) => now - p.made >= keepFor.inMilliseconds).toList();
    final next = [for (final p in _mine) if (!gone.contains(p)) p];
    var changed = gone.isNotEmpty;
    final newest = next.isEmpty ? null : next.reduce((a, b) => b.made > a.made ? b : a);
    if (newest == null || now - newest.made >= rotateEvery.inMilliseconds || newest.made > now + const Duration(days: 1).inMilliseconds) {
      String id;
      do {
        id = NetCrypto.hex(NetCrypto.randomBytes(4));
      } while (next.any((p) => p.id == id));
      next.add(_Prekey(id, NetKeys.generate(), now));
      changed = true;
    }
    if (!changed) return;
    // Kept first: a prekey is never offered, nor an old one forgotten here, until the secret store has the new list. If
    // the write fails, nothing changes (and an expired prekey is still not used: [open] checks its age).
    await _secrets.write(secretsName, jsonEncode([for (final p in next) p.toJson()]));
    _mine
      ..clear()
      ..addAll(next);
    if (gone.isNotEmpty) {
      final ids = {for (final p in gone) p.id};
      _seen.removeWhere((_, prekey) => ids.contains(prekey));
      _saveSeenSoon();
    }
  }

  /// The prekey made last; null where there is none.
  _Prekey? get _newest => _mine.isEmpty ? null : _mine.reduce((a, b) => b.made > a.made ? b : a);

  /// Whether a prekey needs making or deleting now: [refresh] has work.
  bool get due {
    final now = _now().millisecondsSinceEpoch, newest = _newest;
    return newest == null || now - newest.made >= rotateEvery.inMilliseconds || _mine.any((p) => now - p.made >= keepFor.inMilliseconds);
  }

  /// What this device offers: its newest prekey's public half. Null before [load].
  FsBundle? get bundle {
    final p = _newest;
    return p == null ? null : FsBundle(device: device, prekey: p.id, key: p.keys.public, made: p.made);
  }

  /// The names of the prekeys this device still holds the private half of, for a test.
  List<String> get heldPrekeys => [for (final p in _mine) p.id];

  /// Takes a prekey [said] by a device of [peer] (an id): the sealed envelope it came in is what says it is theirs.
  /// One of this device's own is passed over. True where it is newer than what was held for that device.
  bool heard(String peer, Object? said) {
    final b = FsBundle.fromJson(said);
    if (b == null || b.device == device) return false;
    // It can do forward secrecy now: no longer sent an old copy.
    if (_old[peer]?.remove(b.device) != null) {
      if (_old[peer]!.isEmpty) _old.remove(peer);
      _saveOld();
    }
    final now = _now().millisecondsSinceEpoch;
    // A prekey made, by its maker's clock, more than a day ahead of this one's is not believed: it would be sealed to
    // for longer than its maker keeps it.
    if (b.made > now + const Duration(days: 1).inMilliseconds) return false;
    final devices = _peers[peer] ??= {};
    final had = devices[b.device];
    if (had != null && had.made >= b.made) return false;
    devices[b.device] = b;
    while (devices.length > mostDevices) {
      devices.remove(devices.values.reduce((x, y) => y.made < x.made ? y : x).device);
    }
    unawaited(_savePeers());
    return true;
  }

  /// Whether any device of [peer] has offered a prekey this build may seal to now.
  bool canSealTo(String peer) => targets(peer).isNotEmpty;

  /// Notes that a device of [peer] can't do forward secrecy now: [device] where it said which (an `fsk` with
  /// `nofs`, from a device whose forward secrecy hasn't loaded), '' for one that can't say (an old-sealed packet with no
  /// prekey: a build from before). Cleared for a device as soon as it offers a prekey ([heard]).
  void sawOld(String peer, {String device = ''}) {
    final now = _now().millisecondsSinceEpoch;
    final devices = _old[peer] ??= {};
    final had = devices[device];
    devices[device] = now;
    // Written at most once an hour per device: it is a matter of days.
    if (had == null || now - had > const Duration(hours: 1).inMilliseconds) _saveOld();
  }

  // Nothing is written before the load: what is kept would be written over with what this run has heard so far.
  void _saveOld() {
    if (_loaded) unawaited(_plain.write(oldName, jsonEncode(_old)));
  }

  /// Whether what goes to [peer] needs a copy sealed the old way besides (third review, item 3): one of their devices
  /// said, freshly, within [oldDeviceFor], that it can't do forward secrecy, and hasn't offered a prekey since. Their
  /// devices that can still get it forward secret; that one gets the old copy (the envelope's id drops the second).
  bool needsOld(String peer) {
    final now = _now().millisecondsSinceEpoch;
    return (_old[peer] ?? const <String, int>{}).values.any((at) => now - at < oldDeviceFor.inMilliseconds);
  }

  /// The device names in a forward-secret packet's header, those it was sealed for; empty for one that isn't one.
  static List<String> devicesIn(List<int> payload) {
    if (payload.isEmpty) return const [];
    final n = payload[0];
    if (payload.length < 1 + 33 + n * _entry) return const [];
    return [for (var i = 0; i < n; i++) NetCrypto.hex(payload.sublist(34 + i * _entry, 34 + i * _entry + 16))];
  }

  /// The devices of [peer] heard from within [useFor], by name: for this account's own name, its siblings.
  Set<String> devicesOf(String peer) => {for (final b in targets(peer)) b.device};

  /// Whether the packet tagged [tag] was passed on already ([markPassed]).
  bool wasPassed(String tag) => _passed.containsKey(tag);

  /// Marks the packet tagged [tag] as passed on; false where it was already. Kept across restarts.
  bool markPassed(String tag) {
    if (_passed.containsKey(tag)) return false;
    _passed[tag] = 1;
    while (_passed.length > mostPassed) {
      _passed.remove(_passed.keys.first);
    }
    _saveSeenSoon();
    return true;
  }

  /// Whether the packet tagged [tag] is one this device passed on, come back to it, and may be put back on the
  /// account's name once more ([mostPassTries] in all); counts the try.
  bool passAgain(String tag) {
    final tries = _passed[tag];
    if (tries == null || tries >= mostPassTries) return false;
    _passed[tag] = tries + 1;
    _saveSeenSoon();
    return true;
  }

  /// The devices of [peer] a packet to them is sealed for: each one's newest prekey that is younger than [useFor].
  List<FsBundle> targets(String peer) {
    final now = _now().millisecondsSinceEpoch;
    // Silent past [useFor]: forgotten (A8).
    final devices = _peers[peer];
    if (devices != null && devices.values.any((b) => now - b.made >= useFor.inMilliseconds)) {
      devices.removeWhere((_, b) => now - b.made >= useFor.inMilliseconds);
      if (devices.isEmpty) _peers.remove(peer);
      unawaited(_savePeers());
    }
    return [
      for (final b in (_peers[peer] ?? const <String, FsBundle>{}).values)
        if (b.device != device && now - b.made < useFor.inMilliseconds) b,
    ]..sort((a, b) => a.device.compareTo(b.device));
  }

  /// Forgets every device of [peer].
  void forget(String peer) {
    if (_peers.remove(peer) != null) unawaited(_savePeers());
  }

  /// [clear] sealed from [from] to [to] (ids) for [targets], under the pair's key [pairKey]. The one-off key is made
  /// here and dropped as this returns.
  static Uint8List seal({required String from, required String to, required List<int> pairKey, required List<int> clear, required List<FsBundle> targets}) {
    if (targets.isEmpty || targets.length > 255) throw ArgumentError('sealed for 1 to 255 devices');
    final once = NetKeys.generate();
    final content = NetCrypto.randomBytes(32);
    final fromB = NetCrypto.unhex(from), toB = NetCrypto.unhex(to);
    final head = BytesBuilder(copy: false)
      ..addByte(targets.length)
      ..add(once.public);
    for (final t in targets) {
      final shared = NetCrypto.agree(once, t.key);
      if (shared == null) throw ArgumentError('a prekey that is no key');
      final deviceB = NetCrypto.unhex(t.device), prekeyB = NetCrypto.unhex(t.prekey);
      final k = NetCrypto.hkdf(salt: pairKey, ikm: shared, info: [..._wrapInfo, ...fromB, ...toB, ...deviceB, ...prekeyB, ...once.public]);
      final nonce = NetCrypto.randomBytes(12);
      head
        ..add(deviceB)
        ..add(prekeyB)
        ..add(nonce)
        ..add(FastGcm(k).seal(nonce, _wrapAad, content));
    }
    final header = head.toBytes();
    final nonce = NetCrypto.randomBytes(12);
    final body = FastGcm(content).seal(nonce, Uint8List.fromList([..._bodyAad, ...fromB, ...toB, ...header]), Uint8List.fromList(clear));
    return Uint8List.fromList([...header, ...nonce, ...body]);
  }

  /// [seal], on an isolate of its own where [offThread]: a packet for several devices is several EC multiplications.
  /// On one long-lived worker isolate, in the order asked (second review, A7): never hundreds of isolates at once, and
  /// a ring and its cancel sealed in the order they were sent.
  static Future<Uint8List> sealAway({required String from, required String to, required List<int> pairKey, required List<int> clear, required List<FsBundle> targets}) async {
    if (!offThread) return seal(from: from, to: to, pairKey: pairKey, clear: clear, targets: targets);
    final out = await _FsWorker.call(['seal', from, to, Uint8List.fromList(pairKey), Uint8List.fromList(clear), [for (final t in targets) t.toJson()]]);
    // The worker died, timed out or failed: sealed here instead, rather than nothing sent (third review, item 1).
    return out is Uint8List ? out : seal(from: from, to: to, pairKey: pairKey, clear: clear, targets: targets);
  }

  /// Stops the worker isolate (a test's end; the app's lasts as long as it does).
  static void stopWorker() => _FsWorker.stop();

  /// For a test: kills the worker, makes the next starts fail, or has it answer nothing, and how long a job may take.
  static void debugKillWorker() => _FsWorker.kill();
  static set debugFailWorkerStarts(int n) => _FsWorker.failSpawns = n;
  static set debugWorkerHangs(bool on) => _FsWorker.hang = on;
  static set debugWorkerJobFor(Duration d) => _FsWorker.jobFor = d;

  /// For a test: whether a worker is held now (a failed start is not kept).
  static bool get debugWorkerHeld => _FsWorker._one != null;

  /// [open], with its EC multiplication on an isolate of its own where [offThread].
  Future<FsOpened> openAway({required String from, required String to, required List<int> pairKey, required List<int> payload}) async {
    final found = _find(payload);
    if (found.result != null) return FsOpened(found.result!);
    final bytes = Uint8List.fromList(payload);
    final args = (scalar: found.prekey!.keys.scalar, device: device, from: from, to: to, key: Uint8List.fromList(pairKey), payload: bytes, at: found.at!, head: found.headLength!);
    final clear = offThread ? await _unwrapAway(args) : _unwrap(args.scalar, args.device, from, to, args.key, bytes, args.at, args.head);
    return _finish(clear, found.prekey!, bytes);
  }

  /// [_unwrap] on the worker isolate, in order.
  static Future<Uint8List?> _unwrapAway(({Uint8List scalar, String device, String from, String to, Uint8List key, Uint8List payload, int at, int head}) a) async {
    final out = await _FsWorker.call(['open', a.scalar, a.device, a.from, a.to, a.key, a.payload, a.at, a.head]);
    if (out is Uint8List) return out;
    // Not opened there: the worker died or timed out (opened here instead), or it couldn't be opened (nor here).
    return out == _FsWorker.failed ? _unwrap(a.scalar, a.device, a.from, a.to, a.key, a.payload, a.at, a.head) : null;
  }

  /// What the worker isolate does with one job ([_FsWorker]).
  static Object? work(List job) {
    switch (job[0]) {
      case 'seal':
        return seal(from: job[1] as String, to: job[2] as String, pairKey: job[3] as Uint8List, clear: job[4] as Uint8List, targets: [for (final t in job[5] as List) ?FsBundle.fromJson(t)]);
      case 'open':
        return _unwrap(job[1] as Uint8List, job[2] as String, job[3] as String, job[4] as String, job[5] as Uint8List, job[6] as Uint8List, job[7] as int, job[8] as int);
    }
    return null;
  }

  /// Opens [payload], sealed from [from] to [to] under the pair's key [pairKey], with this device's prekeys.
  FsOpened open({required String from, required String to, required List<int> pairKey, required List<int> payload}) {
    final found = _find(payload);
    if (found.result != null) return FsOpened(found.result!);
    return _finish(_unwrap(found.prekey!.keys.scalar, device, from, to, pairKey, payload, found.at!, found.headLength!), found.prekey!, payload);
  }

  /// Finds this device's entry in [payload]'s header: where it starts ([at]), how long the header is, and the prekey
  /// it names, where this device still holds it. Else [result] says why the packet can't be opened here.
  ({FsResult? result, _Prekey? prekey, int? at, int? headLength}) _find(List<int> payload) {
    if (payload.length < 1 + 33 + 28) return (result: FsResult.bad, prekey: null, at: null, headLength: null);
    final n = payload[0];
    final headLength = 1 + 33 + n * _entry;
    if (n == 0 || payload.length < headLength + 28) return (result: FsResult.bad, prekey: null, at: null, headLength: null);
    final mine = NetCrypto.unhex(device);
    int? at;
    for (var i = 0; i < n; i++) {
      final o = 34 + i * _entry;
      if (_same(payload, o, mine)) {
        at = o;
        break;
      }
    }
    if (at == null) return (result: FsResult.notForThisDevice, prekey: null, at: null, headLength: null);
    final prekeyName = NetCrypto.hex(payload.sublist(at + 16, at + 20));
    final now = _now().millisecondsSinceEpoch;
    final prekey = _mine.where((p) => p.id == prekeyName && now - p.made < keepFor.inMilliseconds).firstOrNull;
    if (prekey == null) return (result: FsResult.noPrekey, prekey: null, at: null, headLength: null);
    return (result: null, prekey: prekey, at: at, headLength: headLength);
  }

  /// The arithmetic of opening, with nothing of this object in it (so the worker can run it): agrees a key with the
  /// packet's one-off key under the prekey's [scalar], unwraps the content key in this device's entry at [at], and
  /// opens the body with it. Null where any of it does not fit.
  static Uint8List? _unwrap(Uint8List scalar, String device, String from, String to, List<int> pairKey, List<int> payload, int at, int headLength) {
    final onceKey = payload.sublist(1, 34);
    final shared = NetCrypto.agree(NetKeys.fromScalar(scalar), onceKey);
    if (shared == null) return null;
    final mine = NetCrypto.unhex(device);
    final fromB = NetCrypto.unhex(from), toB = NetCrypto.unhex(to);
    final k = NetCrypto.hkdf(salt: pairKey, ikm: shared, info: [..._wrapInfo, ...fromB, ...toB, ...mine, ...payload.sublist(at + 16, at + 20), ...onceKey]);
    try {
      final content = FastGcm(k).open(Uint8List.fromList(payload.sublist(at + 20, at + 32)), _wrapAad, Uint8List.fromList(payload.sublist(at + 32, at + _entry)));
      if (content == null || content.length != 32) return null;
      final header = payload.sublist(0, headLength);
      return FastGcm(content).open(Uint8List.fromList(payload.sublist(headLength, headLength + 12)), Uint8List.fromList([..._bodyAad, ...fromB, ...toB, ...header]), Uint8List.fromList(payload.sublist(headLength + 12)));
    } catch (_) {
      return null;
    }
  }

  /// What opening came to: bad where nothing was opened, a replay where the packet's one-off key was seen before,
  /// else opened, with the key noted as seen.
  FsOpened _finish(Uint8List? clear, _Prekey prekey, List<int> payload) {
    if (clear == null) return const FsOpened(FsResult.bad);
    final onceKey = payload.sublist(1, 34);
    // Seen before: the same one-off key, so the same packet, come again (a replay, or a second route's copy).
    final tag = NetCrypto.hex(NetCrypto.sha256(onceKey).sublist(0, 8));
    if (_seen.containsKey(tag)) return FsOpened(FsResult.replay, clear: clear);
    _seen[tag] = prekey.id;
    while (_seen.length > mostSeen) {
      _seen.remove(_seen.keys.first);
    }
    _saveSeenSoon();
    return FsOpened(FsResult.opened, clear: clear);
  }

  /// Whether [bytes] holds [want] at [at].
  static bool _same(List<int> bytes, int at, List<int> want) {
    for (var i = 0; i < want.length; i++) {
      if (bytes[at + i] != want[i]) return false;
    }
    return true;
  }

  /// Keeps what others' devices offered ([peersName]).
  Future<void> _savePeers() async {
    if (!_loaded) return;
    await _plain.write(peersName, jsonEncode({for (final e in _peers.entries) e.key: {for (final b in e.value.values) b.device: b.toJson()}}));
  }

  /// Writes the seen one-off keys two seconds from now, once for all that are seen meanwhile.
  void _saveSeenSoon() {
    _seenTimer ??= Timer(const Duration(seconds: 2), () => unawaited(flush()));
  }

  /// Writes what is waiting to be written now (the seen one-off keys), for a test and for closing.
  Future<void> flush() async {
    _seenTimer?.cancel();
    _seenTimer = null;
    if (!_loaded) return;
    await _plain.write(seenName, jsonEncode([for (final e in _seen.entries) [e.key, e.value]]));
    await _plain.write(passedName, jsonEncode(_passed));
  }

  /// Deletes everything: this device's prekeys and what it knows of others'. For signing out.
  Future<void> wipe() async {
    _mine.clear();
    _peers.clear();
    _seen.clear();
    _old.clear();
    _passed.clear();
    _seenTimer?.cancel();
    _seenTimer = null;
    await _secrets.write(secretsName, '');
    await _plain.write(peersName, '');
    await _plain.write(seenName, '');
    await _plain.write(oldName, '');
  }
}

/// Where [ForwardSecrecy] keeps things: a secret store for this device's prekeys (the Keychain, Android's vault), and
/// an ordinary one for what others offered and what was seen.
abstract class FsStore {
  Future<String?> read(String name);
  Future<void> write(String name, String value);
}

/// An [FsStore] in memory, for a test.
class MemoryFsStore implements FsStore {
  final Map<String, String> kept = {};
  int writes = 0;
  @override
  Future<String?> read(String name) async => kept[name];
  @override
  Future<void> write(String name, String value) async {
    writes++;
    kept[name] = value;
  }
}

/// A device's prekey, as it offers it: whose device, which prekey, its public half (33 bytes), when it was made.
class FsBundle {
  const FsBundle({required this.device, required this.prekey, required this.key, required this.made});
  final String device;
  final String prekey;
  final Uint8List key;
  final int made;

  Map<String, dynamic> toJson() => {'d': device, 'p': prekey, 'k': base64Encode(key), 'm': made};

  static FsBundle? fromJson(Object? j) {
    if (j is! Map) return null;
    final d = j['d'], p = j['p'], k = j['k'], m = j['m'];
    if (d is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(d) || p is! String || !RegExp(r'^[0-9a-f]{8}$').hasMatch(p) || k is! String || m is! int) return null;
    try {
      final key = base64Decode(k);
      if (key.length != 33 || (key[0] != 2 && key[0] != 3)) return null;
      return FsBundle(device: d, prekey: p, key: key, made: m);
    } catch (_) {
      return null;
    }
  }
}

/// One of this device's prekeys: its name (8 hex digits), its key pair, and when it was made (ms).
class _Prekey {
  _Prekey(this.id, this.keys, this.made);
  final String id;
  final NetKeys keys;
  final int made;

  Map<String, Object> toJson() => {'i': id, 's': NetCrypto.hex(keys.scalar), 'm': made};

  static _Prekey? fromJson(Object? j) {
    if (j is! Map) return null;
    final i = j['i'], s = j['s'], m = j['m'];
    if (i is! String || s is! String || s.length != 64 || m is! int) return null;
    try {
      return _Prekey(i, NetKeys.fromScalar(NetCrypto.unhex(s)), m);
    } catch (_) {
      return null;
    }
  }
}

/// What became of opening a forward-secret packet.
enum FsResult {
  /// Opened, for the first time.
  opened,

  /// Opened, and seen before: passed over, answered at most.
  replay,

  /// It carries no key for this device: sealed before the sender heard of it.
  notForThisDevice,

  /// For this device, under a prekey it no longer holds (deleted, or from before a reinstall).
  noPrekey,

  /// Changed, cut short, or not from whom it says.
  bad,
}

/// What opening a forward-secret packet gave: how it went, and the packet's contents where it was opened (a replay's
/// too).
class FsOpened {
  const FsOpened(this.result, {this.clear});
  final FsResult result;
  final Uint8List? clear;
}

/// One long-lived isolate that seals and opens forward-secret packets in the order asked: jobs go in a queue, answers
/// come back in the same order (second review, A7). Supervised (third review, item 1): if it dies or errs every job
/// waiting is answered [failed] and the next call starts a new one; each job has [jobFor] to answer; a start that
/// failed is not kept. A caller answered [failed] does the work itself.
class _FsWorker {
  static _FsWorker? _one;

  /// What a job that the worker never answered is answered with.
  static const failed = 'failed';

  /// How long a job may take before it is taken as lost.
  static Duration jobFor = const Duration(seconds: 5);

  /// For a test: the next [failSpawns] starts fail; [hang] has the worker answer nothing.
  static int failSpawns = 0;
  static bool hang = false;

  /// Gives [job] to the worker, started where there is none, and answers what it made of it, or [failed].
  static Future<Object?> call(List job) async {
    final w = _one ??= _FsWorker();
    try {
      return await w._call(job);
    } catch (_) {
      if (identical(_one, w)) _one = null;
      return failed;
    }
  }

  /// Lets the worker go; the next call starts another.
  static void stop() => _one?._die();

  /// For a test: kills the worker as if it had crashed.
  static void kill() => _one?._isolate?.kill(priority: Isolate.immediate);

  /// The isolate, the ports its answers and its end come on, the port jobs go to; then the start under way, the jobs
  /// not yet answered by their numbers, and the next job's number.
  Isolate? _isolate;
  ReceivePort? _from, _exit;
  SendPort? _to;
  Future<void>? _starting;
  final Map<int, Completer<Object?>> _waiting = {};
  int _next = 0;

  /// Every job waiting answered [failed], and this worker let go: the next call starts another.
  void _die() {
    if (identical(_one, this)) _one = null;
    _isolate?.kill(priority: Isolate.immediate);
    _from?.close();
    _exit?.close();
    for (final c in _waiting.values) {
      if (!c.isCompleted) c.complete(failed);
    }
    _waiting.clear();
  }

  /// Starts the isolate and waits, [jobFor] at most, for the port jobs are sent to. Throws where it does not start.
  Future<void> _start() async {
    if (failSpawns > 0) {
      failSpawns--;
      throw StateError('could not start the worker');
    }
    final from = _from = ReceivePort();
    final exit = _exit = ReceivePort();
    final ready = Completer<SendPort>();
    from.listen((m) {
      if (m is SendPort) {
        if (!ready.isCompleted) ready.complete(m);
      } else if (m is List && m.length == 2) {
        _waiting.remove(m[0])?.complete(m[1]);
      }
    });
    // Its end or an error it didn't catch: everything waiting fails, and it is let go.
    exit.listen((_) => _die());
    try {
      _isolate = await Isolate.spawn(_main, [from.sendPort, hang], onExit: exit.sendPort, onError: exit.sendPort, errorsAreFatal: true);
      _to = await ready.future.timeout(jobFor);
    } catch (_) {
      _die();
      rethrow;
    }
  }

  /// Sends [job] under a number of its own and waits for the answer with that number, [jobFor] at most.
  Future<Object?> _call(List job) async {
    // A start that failed is not kept: the throw reaches [call], which lets this worker go.
    await (_starting ??= _start());
    final id = _next++;
    final c = _waiting[id] = Completer<Object?>();
    _to!.send([id, job]);
    return c.future.timeout(jobFor, onTimeout: () {
      _waiting.remove(id);
      // A worker that hangs is let go too, or every later job would wait out its five seconds.
      _die();
      return failed;
    });
  }

  /// The isolate's own side: sends back the port it takes jobs on, then answers each job with its number and what
  /// [ForwardSecrecy.work] made of it (null where that threw).
  static void _main(List args) {
    final back = args[0] as SendPort, hang = args[1] as bool;
    final jobs = ReceivePort();
    back.send(jobs.sendPort);
    jobs.listen((m) {
      if (hang) return;
      final id = (m as List)[0];
      Object? out;
      try {
        out = ForwardSecrecy.work(m[1] as List);
      } catch (_) {
        out = null;
      }
      back.send([id, out]);
    });
  }
}
