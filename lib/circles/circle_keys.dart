import 'dart:async';
import 'dart:convert';
import '../aside.dart';
import 'dart:typed_data';

import '../net/crypto.dart';
import '../net/fast_gcm.dart';
import '../net/forward_secrecy.dart' show FsStore, MemoryFsStore;
import '../net/hub_carrier.dart' show NetSigner;
import 'circle.dart';

/// A circle's key, changed when someone is put out of it (GMFB-26, from the Uplink gap review: "rotate the circle's
/// key when a member is removed"). docs/FORWARD_SECRECY.md is the whole design.
///
/// **Before this** a circle's room, and each of its spaces' chat, were sealed with keys made from seeds every member
/// holds (Circle.key, VoiceChannel.key). Someone banned kept the seeds, so a changed app could go on reading
/// everything said after, silently.
///
/// **Epochs.** When the owner or an admin bans or kicks someone, their device makes a new random key for the circle
/// (epoch 1, 2, …) and signs a header naming it: the circle, the number, a commitment to the key (an HMAC under it),
/// who signed and when. The key itself goes to each member's device sealed to that device alone: every device of a
/// member says a key pair of its own for this (an "inbox", random, kept on the device, never made from the account's
/// words), signed by its identity, in the circle's room. Whoever was put out gets no box.
///
/// From then on what is said in the circle's room (its manifest, joins) and in its spaces' chat is sealed under a key
/// made from both the epoch's key and the seed's own (HKDF), with the epoch and a piece of the commitment in front:
///
///     [3: "GE1"][4: the epoch, big-endian][4: the commitment's first 4 bytes][12: nonce][AES-256-GCM, 16 tag]
///
/// So the seed alone, which the banned person still has, opens nothing sealed after, and a key from an earlier epoch
/// opens nothing of a later one. What is sealed the old way still opens (a build from before goes on with it).
///
/// **Coming later.** A member's device that hasn't got the newest key (away when it changed, a new device, a member let
/// back) asks for it (`k?`, with its inbox); a member's device that has it answers with a box for that inbox and the
/// signed header. The key in a box is taken only where it matches the commitment in a header signed by the owner or an
/// admin, so nobody can hand out a key of their own making.
class CircleKeys {
  CircleKeys({required FsStore secrets, String? device})
      : _secrets = secrets,
        device = device != null && RegExp(r'^[0-9a-f]{32}$').hasMatch(device) ? device : NetCrypto.hex(NetCrypto.randomBytes(16));

  /// Ready at once, kept in memory: for a test.
  factory CircleKeys.fresh({String? device}) => CircleKeys(secrets: MemoryFsStore(), device: device)
    .._inbox = NetKeys.generate()
    .._loaded = true;

  /// The app's own, set by Circles as it starts; HangoutRoom seals a circle space's chat with it.
  static CircleKeys? app;

  /// Whether this device takes part in circle keys at all: holds an inbox and says it, takes a key handed to it, asks
  /// for one it lacks, and opens and seals what a circle's newest key covers. On since 2026-11-26 (GMFB-26, step 1 of
  /// docs/FORWARD_SECRECY.md's "Switching it on"), so that by the time keys are made every device that has updated can
  /// read them. Off, every circle is sealed with its seed's keys and nothing of this is said in its rooms, as before.
  static bool enabled = true;

  /// Whether this device makes a circle a new key when someone is put out of it ([Circles.rotateKey]). Off: while
  /// builds from before [enabled] are about, a new key would lock them out of the circle at its first removal, and
  /// that can't be undone for a circle. Switched on once nearly every device has updated (Matt's call). A test of the
  /// circle keys switches it on.
  static bool makes = false;

  final FsStore _secrets;

  /// Which of its identity's devices this is (HubCarrier.device): boxes are sealed per device.
  String device;

  /// This device's key pair for boxes: new keys are sealed to its public half.
  late NetKeys _inbox;
  bool _loaded = false;
  bool get loaded => _loaded;

  /// The headers heard and believed, by circle seed.
  final Map<String, List<CircleEpoch>> _epochs = {};

  /// The epochs' keys this device holds, by circle seed, then `epoch:tag`.
  final Map<String, Map<String, Uint8List>> _keys = {};
  Future<void> _writing = Future.value();

  /// When this device last said its inbox in each circle's room to be kept by the relay (ms): once a day at most, else
  /// live, so its 300 kept packets aren't filled with inboxes (review finding 8).
  final Map<String, int> _keptInbox = {};

  /// Told the seed of a circle whose newest key this device lacks and needs (a space's packet it couldn't open), so its
  /// room asks for it.
  void Function(String seed)? onMissing;

  /// The seed of each circle a key was taken for: what waited for it (posts, packets) goes on.
  final _taken = StreamController<String>.broadcast();
  Stream<String> get taken => _taken.stream;

  /// The highest epoch there may be: the header's field is 32 bits.
  static const epochMost = 0xffff0000;

  /// The name all of this is kept under in the secrets store.
  static const secretsName = 'circle_keys';

  // What a packet sealed under an epoch's key starts with, and how long its head is: the mark, the epoch, the tag.
  static final _magic = utf8.encode('GE1');
  static const _head = 3 + 4 + 4;

  /// The most boxes said in one message: each is about 200 bytes, and a packet on the hub at most 64 KB.
  static const boxesPerMessage = 200;

  Uint8List get inboxKey => _inbox.public;

  /// Reads what is kept: this device's name and inbox, and each circle's headers and keys. A first run makes the
  /// inbox and keeps it.
  Future<void> load() async {
    final kept = await _secrets.read(secretsName);
    _epochs.clear();
    _keys.clear();
    NetKeys? inbox;
    if (kept != null && kept.isNotEmpty) {
      final j = jsonDecode(kept) as Map;
      if (j['d'] is String && RegExp(r'^[0-9a-f]{32}$').hasMatch(j['d'] as String)) device = j['d'] as String;
      if (j['i'] is String && (j['i'] as String).length == 64) inbox = NetKeys.fromScalar(NetCrypto.unhex(j['i'] as String));
      for (final e in ((j['c'] as Map?) ?? const {}).entries) {
        final seed = '${e.key}', v = e.value;
        if (v is! Map) continue;
        _epochs[seed] = [for (final h in (v['h'] as List? ?? const [])) ?CircleEpoch.fromJson(h)];
        _keys[seed] = {for (final k in ((v['k'] as Map?) ?? const {}).entries) if (k.value is String && (k.value as String).length == 64) '${k.key}': NetCrypto.unhex(k.value as String)};
      }
      for (final e in ((j['ik'] as Map?) ?? const {}).entries) {
        if (e.value is int) _keptInbox['${e.key}'] = e.value as int;
      }
    }
    final made = inbox == null;
    _inbox = inbox ?? NetKeys.generate();
    _loaded = true;
    if (made) await _save();
  }

  /// Keeps everything, as [load] reads it; writes go one after another.
  Future<void> _save() {
    final text = jsonEncode({
      'd': device,
      'i': NetCrypto.hex(_inbox.scalar),
      'c': {
        for (final seed in {..._epochs.keys, ..._keys.keys})
          seed: {
            'h': [for (final h in _epochs[seed] ?? const <CircleEpoch>[]) h.toJson()],
            'k': {for (final k in (_keys[seed] ?? const <String, Uint8List>{}).entries) k.key: NetCrypto.hex(k.value)},
          },
      },
      'ik': _keptInbox,
    });
    return _writing = _writing.catchError((_) {}).then((_) => _secrets.write(secretsName, text));
  }

  /// Everything written, for a test.
  Future<void> flushed() => _writing;

  // --- where a circle stands ------------------------------------------------------------------------------------------

  /// The headers of [seed]'s circle taken. A header is judged as it is taken (its signer may change the circle then)
  /// and stays believed after, even if its signer stops being an admin (second review, B1): dropping it would have
  /// this device fall back to an older key, or the seed's, which someone put out holds. A newer epoch supersedes it.
  Iterable<CircleEpoch> _trusted(String seed) => _epochs[seed] ?? const <CircleEpoch>[];

  /// The names of headers this device made itself (`seed:epoch:tag`): only their maker changes the key again when two
  /// admins changed it at once (B3).
  final Set<String> _madeHere = {};

  /// The epochs this device has changed the key again for, after two admins changed it at once: once each (B3).
  final Set<String> _againFor = {};

  /// Whether this device should change [seed]'s circle's key again: two believed headers name its newest epoch, one of
  /// them this device's and not the one that wins (the lower commitment), and it hasn't done so for this epoch yet.
  bool shouldChangeAgain(String seed) {
    final n = newest(seed);
    if (n == null || !split(seed)) return false;
    final lost = _trusted(seed).any((h) => h.epoch == n.epoch && h.commit != n.commit && _madeHere.contains('$seed:${h.name}'));
    return lost && !_againFor.contains('$seed:${n.epoch}');
  }

  /// Notes that this device is changing [seed]'s circle's key again for its newest epoch.
  void changingAgain(String seed) {
    final n = newest(seed);
    if (n != null) _againFor.add('$seed:${n.epoch}');
  }

  /// The newest epoch of [seed]'s circle this device holds the key of; null for none (the seed's own keys).
  CircleEpoch? current(String seed) {
    final held = _keys[seed] ?? const {};
    CircleEpoch? best;
    for (final h in _trusted(seed)) {
      if (!held.containsKey(h.name)) continue;
      if (best == null || h.epoch > best.epoch || (h.epoch == best.epoch && h.commit.compareTo(best.commit) < 0)) best = h;
    }
    return best;
  }

  /// The newest epoch of [seed]'s circle heard of, held or not.
  CircleEpoch? newest(String seed) {
    CircleEpoch? best;
    for (final h in _trusted(seed)) {
      if (best == null || h.epoch > best.epoch || (h.epoch == best.epoch && h.commit.compareTo(best.commit) < 0)) best = h;
    }
    return best;
  }

  /// Whether a newer epoch of [seed]'s circle is known than this device holds the key of: it should ask.
  bool lacking(String seed) {
    final n = newest(seed);
    if (n == null) return false;
    final c = current(seed);
    return c == null || n.epoch > c.epoch;
  }

  /// Whether two believed headers name the newest epoch of [seed]'s circle with different keys: two admins changed it
  /// at once (finding 7). The owner or an admin changes it again.
  bool split(String seed) {
    final n = newest(seed);
    if (n == null) return false;
    return _trusted(seed).any((h) => h.epoch == n.epoch && h.commit != n.commit);
  }

  /// Whether this device should say its inbox in [seed]'s circle's room to be kept: not in the last day.
  bool keepInboxNow(String seed) {
    final last = _keptInbox[seed];
    return last == null || DateTime.now().millisecondsSinceEpoch - last > const Duration(days: 1).inMilliseconds;
  }

  /// This device said its inbox in [seed]'s circle's room to be kept, now.
  void keptInbox(String seed) {
    _keptInbox[seed] = DateTime.now().millisecondsSinceEpoch;
    unawaited(_save());
  }

  /// A packet of [seed]'s circle came under a key this device lacks: its room asks.
  void missing(String seed) => onMissing?.call(seed);

  /// Forgets [seed]'s circle: left.
  Future<void> forget(String seed) async {
    final had = _epochs.remove(seed) != null;
    if (_keys.remove(seed) == null && !had && _keptInbox.remove(seed) == null) return;
    _keptInbox.remove(seed);
    await _save();
  }

  /// Forgets every circle's keys and makes a new inbox: signing out.
  Future<void> wipe() async {
    _epochs.clear();
    _keys.clear();
    _keptInbox.clear();
    _inbox = NetKeys.generate();
    await _save();
  }

  // --- inboxes ----------------------------------------------------------------------------------------------------------

  /// What a device's identity signs to say an inbox is its own: the circle, the device and the inbox's key.
  static List<int> inboxMessage(String seed, String device, List<int> inbox) => utf8.encode('ghost-circle inbox v1|$seed|$device|${NetCrypto.hex(inbox)}');

  /// What this device says in [seed]'s circle's room so that a new key can be sealed to it: its inbox, signed by
  /// [signer] (its identity).
  Future<Map<String, Object?>> inboxSaid(String seed, NetSigner signer) async => {
        't': 'ik',
        'k': NetCrypto.hex(signer.publicKey),
        'd': device,
        'b': NetCrypto.hex(_inbox.public),
        'sig': NetCrypto.hex(await signer.sign(inboxMessage(seed, device, _inbox.public))),
      };

  /// The inbox [said] in [seed]'s circle's room by [from] (as the relay stamped it), where it is theirs; null otherwise.
  static CircleInbox? inboxOf(String seed, String from, Object? said) {
    if (said is! Map) return null;
    final k = said['k'], d = said['d'], b = said['b'], sig = said['sig'];
    if (k is! String || d is! String || b is! String || sig is! String) return null;
    if (!RegExp(r'^0[23][0-9a-f]{64}$').hasMatch(k) || !RegExp(r'^[0-9a-f]{32}$').hasMatch(d) || !RegExp(r'^0[23][0-9a-f]{64}$').hasMatch(b) || sig.length != 128) return null;
    final key = NetCrypto.unhex(k), inbox = NetCrypto.unhex(b);
    if (NetCrypto.idOf(key) != from) return null;
    if (!NetCrypto.verifyOnce(key, inboxMessage(seed, d, inbox), NetCrypto.unhex(sig))) return null;
    return CircleInbox(id: from, device: d, key: inbox);
  }

  // --- a new key --------------------------------------------------------------------------------------------------------

  /// The commitment to an epoch's [key] that its header carries: an HMAC under the key, naming the circle and the
  /// epoch. A key that came in a box is checked against it.
  static String commitOf(String seed, int epoch, List<int> key) => NetCrypto.hex(NetCrypto.hmac(key, utf8.encode('ghost-circle commit v1|$seed|$epoch')));

  /// A new key for [c], one epoch past the newest heard of, signed by [signer] (the owner or an admin), held here, and
  /// the messages that hand it to each of [to] (boxes, [boxesPerMessage] to a message): the first `rk`, any more `kb`.
  /// Null where [signer] may not change [c].
  Future<List<Map<String, Object?>>?> rotate(Circle c, NetSigner signer, Iterable<CircleInbox> to) async {
    if (!c.manifest.canSign(signer.id)) return null;
    final epoch = (newest(c.seed)?.epoch ?? 0) + 1;
    if (epoch > epochMost) return null;
    final key = NetCrypto.randomBytes(32);
    final unsigned = CircleEpoch(seed: c.seed, epoch: epoch, commit: commitOf(c.seed, epoch, key), by: signer.id, byKey: NetCrypto.hex(signer.publicKey), at: DateTime.now().millisecondsSinceEpoch, sig: '', gv: c.manifest.grantsVersion);
    final header = unsigned.withSig(NetCrypto.hex(await signer.sign(unsigned.signed)));
    (_epochs[c.seed] ??= []).add(header);
    (_keys[c.seed] ??= {})[header.name] = key;
    _madeHere.add('${c.seed}:${header.name}');
    unawaited(_save());
    // Each box is an EC key made and multiplied: built on an isolate of their own, off the screens' (finding 9).
    final boxes = await _boxesAway(c.key, c.seed, header, key, [for (final i in to) if (!(i.id == signer.id && i.device == device)) i]);
    final out = <Map<String, Object?>>[];
    for (var i = 0; i == 0 || i < boxes.length; i += boxesPerMessage) {
      out.add({'t': i == 0 ? 'rk' : 'kb', 'h': header.toJson(), 'x': boxes.sublist(i, i + boxesPerMessage > boxes.length ? boxes.length : i + boxesPerMessage)});
    }
    return out;
  }

  /// The newest key held for [c], boxed for [to] alone, with its signed header: an answer to `k?`. Null where none.
  Map<String, Object?>? handOn(Circle c, CircleInbox to) {
    final all = handOnSince(c, to, (current(c.seed)?.epoch ?? 1) - 1);
    return all.isEmpty ? null : all.last;
  }

  /// Every key held for [c] after epoch [since] (the asker's newest), oldest first, each boxed for [to] with its signed
  /// header: so a device away through several changes reads what was said in each (finding 4).
  ///
  /// [after] (ms): only epochs whose header was made after it, for someone kicked who came back, so they read nothing
  /// from while they were out (B9).
  List<Map<String, Object?>> handOnSince(Circle c, CircleInbox to, int since, {int after = 0}) {
    final held = _keys[c.seed] ?? const {};
    final out = <Map<String, Object?>>[];
    final list = _trusted(c.seed).where((h) => h.epoch > since && h.at > after && held.containsKey(h.name)).toList()..sort((a, b) => a.epoch.compareTo(b.epoch));
    for (final h in list) {
      final box = _box(c.key, c.seed, h, held[h.name]!, to);
      if (box != null) out.add({'t': 'kb', 'h': h.toJson(), 'x': [box]});
    }
    return out;
  }

  /// What a box's key is bound to: the circle, the epoch and its commitment, and the one device it is for.
  static List<int> _boxInfo(String seed, CircleEpoch h, String id, String device) => utf8.encode('ghost-circle box v1|$seed|${h.epoch}|${h.commit}|$id|$device');

  /// An epoch's [key] sealed to one device's inbox: a key pair made for this box alone agrees a secret with the inbox,
  /// and the box carries its public half (`o`) with the sealed key (`s`). Null where the inbox's key is no key.
  static Map<String, Object?>? _box(Uint8List circleKey, String seed, CircleEpoch h, Uint8List key, CircleInbox to) {
    final once = NetKeys.generate();
    final shared = NetCrypto.agree(once, to.key);
    if (shared == null) return null;
    final k = NetCrypto.hkdf(salt: circleKey, ikm: shared, info: _boxInfo(seed, h, to.id, to.device));
    return {'i': to.id, 'd': to.device, 'o': NetCrypto.hex(once.public), 's': base64Encode(NetCrypto.seal(k, key))};
  }

  /// Whether boxes are built on an isolate of their own.
  static bool offThread = true;

  /// A box for each of [to], built off the screens' isolate where there is more than one.
  static Future<List<Map<String, Object?>>> _boxesAway(Uint8List circleKey, String seed, CircleEpoch h, Uint8List key, List<CircleInbox> to) async {
    List<Map<String, Object?>> make() => [for (final i in to) ?_box(circleKey, seed, h, key, i)];
    if (!offThread || to.length < 2) return make();
    return runAside(make);
  }

  /// Takes an `rk` or `kb` heard in [c]'s room by this device's identity [me]: the header where the owner or an admin
  /// signed it, and the key in this device's box where it matches the header. True where a key was taken.
  bool take(Circle c, String me, Map said) {
    final h = CircleEpoch.fromJson(said['h']);
    if (h == null || h.seed != c.seed || !h.trusted(c.manifest)) return false;
    // Any epoch up to [epochMost] is taken as known (B4): a device far behind knows it lacks the newest and seals
    // nothing until it has it, rather than refusing the header and sealing with the seed's key.
    final known = _epochs[c.seed] ??= [];
    var changed = false;
    if (!known.any((x) => x.name == h.name && x.commit == h.commit)) {
      known.add(h);
      changed = true;
    }
    var took = false;
    if (!(_keys[c.seed]?.containsKey(h.name) ?? false)) {
      for (final b in (said['x'] is List ? said['x'] as List : const [])) {
        if (b is! Map || b['i'] != me || b['d'] != device || b['o'] is! String || b['s'] is! String) continue;
        try {
          final shared = NetCrypto.agree(_inbox, NetCrypto.unhex(b['o'] as String));
          if (shared == null) continue;
          final k = NetCrypto.hkdf(salt: c.key, ikm: shared, info: _boxInfo(c.seed, h, me, device));
          final key = NetCrypto.open(k, base64Decode(b['s'] as String));
          // Only the key the header's signer committed to: nobody else's.
          if (key == null || key.length != 32 || commitOf(c.seed, h.epoch, key) != h.commit) continue;
          (_keys[c.seed] ??= {})[h.name] = key;
          took = changed = true;
          break;
        } catch (_) {}
      }
    }
    if (changed) unawaited(_save());
    // Told on any change, so what waits for the key goes as soon as nothing newer is lacking (B5).
    if (changed) _taken.add(c.seed);
    return took;
  }

  // --- sealing --------------------------------------------------------------------------------------------------------

  /// The key things are sealed under in an epoch: made from the epoch's key and the seed's own key for the room
  /// ([base]), apart for each purpose and epoch.
  static Uint8List _keyFor(List<int> epochKey, List<int> base, String purpose, int epoch) => NetCrypto.hkdf(salt: epochKey, ikm: base, info: utf8.encode('ghost-circle epoch v1|$purpose|$epoch'));

  /// What is authenticated beside the sealed bytes: the packet's head and the purpose, so neither can be changed.
  static Uint8List _aad(List<int> head, String purpose) => Uint8List.fromList([...head, ...utf8.encode('|$purpose')]);

  /// [clear] sealed for [seed]'s circle with the newest key held, from [base] (the seed's own key for this room) and
  /// [purpose] ('circle' its room, 'space' a space's chat); the old way, with [base] alone, where no epoch is held.
  /// Null where a newer epoch is known than this device holds: nothing is sealed under a key someone put out may hold
  /// (finding 3). The caller keeps it until the key comes ([taken]).
  Uint8List? seal(String seed, List<int> base, String purpose, List<int> clear) {
    if (lacking(seed)) return null;
    final h = current(seed);
    final epochKey = h == null ? null : _keys[seed]?[h.name];
    if (h == null || epochKey == null) return NetCrypto.seal(base, clear);
    final head = Uint8List(_head)
      ..setAll(0, _magic)
      ..buffer.asByteData().setUint32(3, h.epoch)
      ..setAll(7, NetCrypto.unhex(h.tag));
    final nonce = NetCrypto.randomBytes(12);
    return Uint8List.fromList([...head, ...nonce, ...FastGcm(_keyFor(epochKey, base, purpose, h.epoch)).seal(nonce, _aad(head, purpose), Uint8List.fromList(clear))]);
  }

  /// [bytes] opened for [seed]'s circle: under an epoch's key where it says one and this device holds it, or the old
  /// way with [base]. [unknown] where it was sealed under an epoch this device doesn't hold: it should ask.
  ({Uint8List? clear, bool unknown}) open(String seed, List<int> base, String purpose, List<int> bytes) {
    final b = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    var unknown = false;
    if (b.length > _head + 28 && b[0] == _magic[0] && b[1] == _magic[1] && b[2] == _magic[2]) {
      final epoch = ByteData.sublistView(b, 3, 7).getUint32(0);
      final name = '$epoch:${NetCrypto.hex(b.sublist(7, 11))}';
      final epochKey = _keys[seed]?[name];
      if (epochKey != null) {
        final clear = FastGcm(_keyFor(epochKey, base, purpose, epoch)).open(Uint8List.sublistView(b, _head, _head + 12), _aad(b.sublist(0, _head), purpose), Uint8List.sublistView(b, _head + 12));
        if (clear != null) return (clear: clear, unknown: false);
      } else {
        unknown = true;
      }
    }
    // The old way: what a build from before says, and the one in sixteen million sealed the old way that starts "GE1".
    final clear = NetCrypto.open(base, b);
    return (clear: clear, unknown: clear == null && unknown);
  }
}

/// A member's device's inbox in a circle: who (their id), which device, its public key.
class CircleInbox {
  const CircleInbox({required this.id, required this.device, required this.key});
  final String id;
  final String device;
  final Uint8List key;
}

/// A circle's key epoch, as its owner or an admin signed it: which circle, its number, a commitment to its key, who
/// signed, when.
class CircleEpoch {
  const CircleEpoch({required this.seed, required this.epoch, required this.commit, required this.by, required this.byKey, required this.at, required this.sig, this.gv = 0});

  /// The circle's admin list generation (CircleManifest.grantsVersion) its signer could sign under when they made it
  /// (B1), signed with the rest.
  final int gv;
  final String seed;
  final int epoch;

  /// The commitment to the epoch's key ([CircleKeys.commitOf]), 64 hex characters.
  final String commit;

  /// Who signed it (their id), their public key in hex, when (ms since the epoch), and the signature in hex.
  final String by;
  final String byKey;
  final int at;
  final String sig;

  /// The commitment's first 4 bytes, as a sealed packet names its epoch's key.
  String get tag => commit.substring(0, 8);

  /// How this device keeps the key: `epoch:tag`.
  String get name => '$epoch:$tag';

  /// The bytes its signer signs: every field but the signature.
  List<int> get signed => utf8.encode('ghost-circle epoch v2|$seed|$epoch|$commit|$by|$byKey|$at|$gv');

  CircleEpoch withSig(String s) => CircleEpoch(seed: seed, epoch: epoch, commit: commit, by: by, byKey: byKey, at: at, sig: s, gv: gv);

  /// Whether it is signed by whom it says, and they may change the circle whose manifest is [m]: its owner or an admin.
  bool trusted(CircleManifest m) {
    try {
      final key = NetCrypto.unhex(byKey);
      return NetCrypto.idOf(key) == by && m.canSign(by) && NetCrypto.verifyOnce(key, signed, NetCrypto.unhex(sig));
    } catch (_) {
      return false;
    }
  }

  Map<String, Object> toJson() => {'s': seed, 'e': epoch, 'c': commit, 'by': by, 'k': byKey, 'at': at, 'sig': sig, 'gv': gv};

  static CircleEpoch? fromJson(Object? j) {
    if (j is! Map) return null;
    final s = j['s'], e = j['e'], c = j['c'], by = j['by'], k = j['k'], at = j['at'], sig = j['sig'];
    if (s is! String || e is! int || e < 1 || e > CircleKeys.epochMost || c is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(c) || by is! String || k is! String || at is! int || sig is! String || sig.length != 128) return null;
    return CircleEpoch(seed: s, epoch: e, commit: c, by: by, byKey: k, at: at, sig: sig, gv: j['gv'] is int ? j['gv'] as int : 0);
  }
}
