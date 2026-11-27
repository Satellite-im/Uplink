import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'kept_log.dart';
import 'p256.dart';
import 'sha256.dart';

/// A home record: where an account lives, signed by the account (docs/OPEN_NETWORK.md, section 1; Matt, 2026-11-22:
/// "I'd like the relays to be able to talk to each other"). It is the one thing a relay believes about where someone
/// is: nobody's say-so, the account's own key over these bytes.
///
///     {"v":1, "a": account name, "k": public key (33 bytes, base64), "h": [1 to 3 relay addresses],
///      "n": a count that only goes up, "t": made (ms), "s": signature (r then s, base64)}
///
/// What is signed ([signedBytes]): the words `ghost-home v1` and a newline, then the name (16 bytes), the count (4
/// bytes, big end first), the time (8 bytes), how many addresses (1 byte), and each address as its length (1 byte)
/// and its bytes. The app makes and checks the same bytes (lib/net/home_record.dart), and both are held to
/// test/home_record_vectors.json.
///
/// An address is a hub's (`wss://host/hub`), or a relay hosted from an app's (`ghost-relay://<relay name>?n=<node
/// id>&via=<the public relay it stays linked to>`): [HomeAddress].
///
/// A record is good for [goodFor] from when it was made, and says nothing after ([ends]); the app makes the next well
/// before. Of two for one account the one believed is the higher count, then the later made, then the greater
/// signature ([order]), so every relay and app believes the same one.
class HomeRecord {
  HomeRecord._(this.a, this.k, this.h, this.n, this.t, this.s);

  /// The account's name: the first 16 bytes of the SHA-256 of [k], in hex.
  final String a;

  /// The account's public key, 33 bytes.
  final Uint8List k;

  /// Where it lives, as it wrote them.
  final List<String> h;

  /// The count: of two records for one account the higher is the one believed.
  final int n;

  /// When it was made, in milliseconds.
  final int t;

  /// The account's signature over [signedBytes]: r then s, 64 bytes.
  final Uint8List s;

  /// The words every signature begins with; the most addresses a record names, the longest one may be (it is signed
  /// with a single byte of length), and the highest the count goes (it is signed as four bytes).
  static const words = 'ghost-home v1\n';
  static const maxAddresses = 3;
  static const maxAddress = 200;
  static const maxCount = 0xffffffff;

  /// The furthest ahead of this relay's clock a record's time may be: a clock a little fast is forgiven, a record
  /// dated next year is not.
  static const ahead = Duration(minutes: 5);

  /// The longest a record is as JSON: what a store of them is counted by.
  static const maxJson = 1100;

  /// How long a record is good for, from its time: after it, a relay someone has left can't speak for them by an old
  /// record they signed, however long ago that relay forgot the newer one (found in review, 2026-11-22). An app makes
  /// a new one when a third of it has gone (lib/net/homes.dart).
  static const goodFor = Duration(days: 30);

  /// When it stops being good, in milliseconds.
  int get ends => t + goodFor.inMilliseconds;

  /// Whether it is good at [now].
  bool goodAt(DateTime now) => now.millisecondsSinceEpoch < ends;

  /// Which of two records for one account is believed: above nothing where it is [x], below where it is [y]. The
  /// higher count; of two with one count (two devices of the account each made one), the later made; of two made at
  /// the same moment too, the one whose signature is the greater, byte by byte. The app orders them the same.
  static int order(HomeRecord x, HomeRecord y) {
    if (x.n != y.n) return x.n.compareTo(y.n);
    if (x.t != y.t) return x.t.compareTo(y.t);
    for (var i = 0; i < x.s.length && i < y.s.length; i++) {
      if (x.s[i] != y.s[i]) return x.s[i].compareTo(y.s[i]);
    }
    return x.s.length.compareTo(y.s.length);
  }

  /// Whether this is believed over [other], a record for the same account.
  bool newerThan(HomeRecord other) => order(this, other) > 0;

  /// An account's name as it is written: 32 lowercase hex digits.
  static final _hex32 = RegExp(r'^[0-9a-f]{32}$');

  /// Printable ASCII and nothing else: an address is compared and logged as it is.
  static bool _plain(String s) => s.isNotEmpty && s.length <= maxAddress && s.codeUnits.every((c) => c > 0x20 && c < 0x7f);

  /// What an account signs to say it lives at [h], as record number [n], made at [t].
  static Uint8List signedBytes({required String a, required int n, required int t, required List<String> h}) {
    final out = BytesBuilder()
      ..add(utf8.encode(words))
      ..add([for (var i = 0; i < 32; i += 2) int.parse(a.substring(i, i + 2), radix: 16)])
      ..add((ByteData(4)..setUint32(0, n)).buffer.asUint8List())
      ..add((ByteData(8)..setUint64(0, t)).buffer.asUint8List())
      ..addByte(h.length);
    for (final address in h) {
      final bytes = ascii.encode(address);
      out
        ..addByte(bytes.length)
        ..add(bytes);
    }
    return out.toBytes();
  }

  /// The record [json] is, where every part of it is as the plan lays it out, it is still good at [now], and the
  /// signature is the account's own; else why not, in a word (`shape`, `name`, `addresses`, `count`, `time`,
  /// `future`, `old`, `signature`). Everything but the signature is looked at first: it alone costs anything.
  ///
  /// [verify] false passes over the signature and the time ahead: for what this relay checked before it kept it.
  static ({HomeRecord? rec, String? err}) read(Object? json, {required DateTime now, bool verify = true}) {
    ({HomeRecord? rec, String? err}) no(String why) => (rec: null, err: why);
    if (json is! Map || json['v'] != 1) return no('shape');
    final a = json['a'], k = json['k'], h = json['h'], n = json['n'], t = json['t'], s = json['s'];
    if (a is! String || k is! String || h is! List || s is! String || k.length > 64 || s.length > 128) return no('shape');
    final Uint8List key, sig;
    try {
      key = base64Decode(k);
      sig = base64Decode(s);
    } catch (_) {
      return no('shape');
    }
    if (!_hex32.hasMatch(a) || key.length != 33 || sig.length != 64) return no('shape');
    if (hexOf(sha256(key).sublist(0, 16)) != a) return no('name');
    if (h.isEmpty || h.length > maxAddresses || !h.every((x) => x is String && _plain(x))) return no('addresses');
    if (n is! int || n < 1 || n > maxCount) return no('count');
    if (t is! int || t < 0 || t > 0x1fffffffffffff) return no('time');
    final addresses = List<String>.unmodifiable(h.cast<String>());
    if (verify && t > now.add(ahead).millisecondsSinceEpoch) return no('future');
    if (now.millisecondsSinceEpoch >= t + goodFor.inMilliseconds) return no('old');
    if (verify && !P256.verify(key, signedBytes(a: a, n: n, t: t, h: addresses), sig)) return no('signature');
    return (rec: HomeRecord._(a, key, addresses, n, t, sig), err: null);
  }

  /// The record as it is said on the wire and written to `homes.json`: what [read] reads back.
  Map<String, Object> toJson() => {'v': 1, 'a': a, 'k': base64Encode(k), 'h': h, 'n': n, 't': t, 's': base64Encode(s)};

  /// The addresses a relay can read, in the record's order; one it can't read is passed over.
  late final List<HomeAddress> addresses = [for (final x in h) ?HomeAddress.parse(x)];

  /// Whether [other] is this very record: the same account, count and signature.
  bool same(HomeRecord other) => a == other.a && n == other.n && _equal(s, other.s);

  /// Whether two lists of bytes are the same, byte for byte.
  static bool _equal(List<int> x, List<int> y) {
    if (x.length != y.length) return false;
    for (var i = 0; i < x.length; i++) {
      if (x[i] != y[i]) return false;
    }
    return true;
  }
}

/// One address of a home record as a relay reads it: a hub's, or a relay hosted from an app's.
class HomeAddress {
  /// A hub's address (`wss://host/hub`), or a relay hosted from an app's (`ghost-relay://<name>?…&via=<hub>`).
  const HomeAddress.hub(String this.url)
      : relay = null,
        via = null;
  const HomeAddress.hosted(String this.relay, this.via) : url = null;

  /// A hub's address, as two relays compare them ([canonicalHub]); null for a hosted relay's.
  final String? url;

  /// A hosted relay's name (32 hex); null for a hub's address.
  final String? relay;

  /// The public relay a hosted one stays linked to, as [canonicalHub] writes it; null where it names none (it is then
  /// reached over the direct network alone, which no relay does).
  final String? via;

  static final _hex32 = RegExp(r'^[0-9a-f]{32}$');

  /// What [address] names, or null where it is neither kind.
  static HomeAddress? parse(String address) {
    final Uri u;
    try {
      u = Uri.parse(address);
    } catch (_) {
      return null;
    }
    if (u.scheme == 'ghost-relay') {
      if (!_hex32.hasMatch(u.host) || u.hasPort || u.userInfo.isNotEmpty) return null;
      String? via;
      try {
        final said = u.queryParameters['via'];
        via = said == null ? null : canonicalHub(said);
      } catch (_) {}
      return HomeAddress.hosted(u.host, via);
    }
    final url = canonicalHub(address);
    return url == null ? null : HomeAddress.hub(url);
  }
}

/// A hub's address as two relays compare them: `wss` or `ws`, the host in lower case, the port only where it is not
/// the scheme's own, the path without a slash at its end, and nothing else (no user, query or fragment). Null where
/// [address] is not a hub's address at all. The app writes the same (lib/net/home_record.dart).
String? canonicalHub(String address) {
  if (address.length > HomeRecord.maxAddress) return null;
  final Uri u;
  try {
    u = Uri.parse(address);
  } catch (_) {
    return null;
  }
  final scheme = u.scheme;
  if ((scheme != 'wss' && scheme != 'ws') || u.host.isEmpty || u.userInfo.isNotEmpty || u.hasQuery || u.hasFragment) return null;
  final port = u.hasPort && u.port != (scheme == 'wss' ? 443 : 80) ? ':${u.port}' : '';
  final host = u.host.contains(':') ? '[${u.host}]' : u.host;
  return '$scheme://$host$port${u.path.replaceAll(RegExp(r'/+$'), '')}';
}

/// The home records a relay holds (federation.dart).
///
/// - **Its own people's**: of everyone who gave theirs here themselves, over their own signed-in connection. Kept in
///   `homes.json` in the data folder, across restarts, [maxOwn] at most: one more lets go of whoever gave theirs
///   longest ago (they give it again each time their app signs in).
/// - **Others'** (a friend's record an app gave so the relay can route to them, one another relay gave to show it
///   speaks for someone): in memory, the [maxOthers] used most lately.
///
/// Of two records for one account the one [HomeRecord.order] believes is held, whoever gave it, and none past its end:
/// nothing here is ever made by the relay.
class HomeBook {
  HomeBook({this.file, this.maxOwn = 20000, this.maxOthers = 10000, DateTime Function()? now})
      : _now = now ?? DateTime.now,
        _log = file == null ? null : KeptLog(file);
  final DateTime Function() _now;

  /// Where the relay's own people's records are kept; null keeps nothing across restarts. A log of what changed
  /// (kept_log.dart), appended as changes come and compacted now and then off the event loop: never the whole file
  /// written on it.
  final File? file;
  final KeptLog? _log;

  /// The most records held of this relay's own people, and of others.
  final int maxOwn;
  final int maxOthers;

  /// The records held, by account: its own people's, the one given by its owner longest ago first; and others', the
  /// one used longest ago first.
  final LinkedHashMap<String, HomeRecord> _own = LinkedHashMap();
  final LinkedHashMap<String, HomeRecord> _others = LinkedHashMap();

  /// When each of this relay's own people first gave their record here, by this relay's clock (federation.dart counts
  /// someone who has for a while as established); kept with the records.
  final Map<String, DateTime> _since = {};

  /// When [a] first gave their own record here, by this relay's clock; null where they haven't, or it has gone.
  DateTime? ownSince(String a) => _own.containsKey(a) ? _since[a] : null;

  /// Whether anything kept across restarts has changed since it was last written.
  bool dirty = false;

  /// How many records are held of each kind.
  int get own => _own.length;
  int get others => _others.length;

  /// Whether [a] gave their own record here.
  bool isOwn(String a) => _own.containsKey(a);

  /// The record held for [a], or null (one past its end is let go as it is found). One of the others' is used a
  /// moment ago for it.
  HomeRecord? of(String a) {
    final mine = _own[a];
    if (mine != null) {
      if (mine.goodAt(_now())) return mine;
      _letGoOwn(a);
      return null;
    }
    final other = _others.remove(a);
    if (other == null || !other.goodAt(_now())) return null;
    _others[a] = other;
    return other;
  }

  /// Whether exactly [rec] is held, and good: then it need not be checked again.
  bool holds(String a, int n, List<int> s) {
    final held = _own[a] ?? _others[a];
    return held != null && held.n == n && HomeRecord._equal(held.s, s) && held.goodAt(_now());
  }

  /// Keeps [rec], already checked, where it is believed over what is held for its account (or that has ended); true
  /// where it was kept. [byOwner]: the account gave it itself, here: it is one of this relay's own from now on.
  bool keep(HomeRecord rec, {bool byOwner = false}) {
    final a = rec.a;
    if (!rec.goodAt(_now())) return false;
    final held = _own[a] ?? _others[a];
    final newer = held == null || !held.goodAt(_now()) || rec.newerThan(held);
    if (byOwner) {
      // Given by its owner, here: one of this relay's own, and the last of them to be let go.
      final had = _own.remove(a);
      _others.remove(a);
      _own[a] = newer ? rec : held;
      _since.putIfAbsent(a, _now);
      while (_own.length > maxOwn) {
        _letGoOwn(_own.keys.first);
      }
      if (newer || had == null) _keptOwn(a);
      return newer;
    }
    if (_own.containsKey(a)) {
      // A newer copy of one of this relay's own people's, from someone else: in the older one's place.
      if (newer) {
        _own[a] = rec;
        _keptOwn(a);
      }
      return newer;
    }
    _others.remove(a);
    _others[a] = newer ? rec : held;
    while (_others.length > maxOthers) {
      _others.remove(_others.keys.first);
    }
    return newer;
  }

  /// [a]'s own record, as it is written: the record, and since when it has been given here.
  Map<String, Object?> _entry(String a) => {..._own[a]!.toJson(), 'since': (_since[a] ?? _now()).millisecondsSinceEpoch};

  /// [a]'s own record is new or newer: put in the log, to be written with the next save.
  void _keptOwn(String a) {
    _log?.set(a, _entry(a));
    dirty = true;
  }

  /// Forgets [a]'s own record (past its end, or pushed out by [maxOwn]), here and in the log.
  void _letGoOwn(String a) {
    if (_own.remove(a) == null) return;
    _since.remove(a);
    _log?.remove(a);
    dirty = true;
  }

  /// Reads this relay's own people's records from the file, as the relay starts: the newest [maxOwn], each for its
  /// shape and whether it is still good.
  void load() {
    final log = _log;
    if (log == null) return;
    final now = _now();
    // A file written whole, before (`{"v":1,"own":[records]}`): each record given here since it was made.
    Iterable<MapEntry<String, Object?>> whole(Map all) sync* {
      final list = all['own'] is List ? all['own'] as List : const [];
      for (final j in list) {
        if (j is Map && j['a'] is String) yield MapEntry(j['a'] as String, {...j, 'since': j['t'] is int && (j['t'] as int) < now.millisecondsSinceEpoch ? j['t'] : now.millisecondsSinceEpoch});
      }
    }

    final kept = log.load(whole: whole);
    final entries = kept.entries.toList();
    for (final e in entries.length > maxOwn ? entries.sublist(entries.length - maxOwn) : entries) {
      final j = e.value;
      if (j is! Map) continue;
      // Checked when it was kept; read back for its shape alone (a signature is seven milliseconds of arithmetic, and
      // there may be tens of thousands), and whether it is still good.
      final rec = HomeRecord.read(j, now: now, verify: false).rec;
      if (rec == null || rec.a != e.key) continue;
      _own[rec.a] = rec;
      final since = j['since'];
      _since[rec.a] = since is int ? DateTime.fromMillisecondsSinceEpoch(since, isUtc: true) : now;
    }
    dirty = log.dirty;
  }

  /// Every record of this relay's own people, as the log writes them when it is written whole.
  Map<String, Object?> _all() => {for (final a in _own.keys) a: _entry(a)};

  /// Writes what changed: appended to the log, off the event loop.
  Future<void> save() {
    final log = _log;
    if (log == null || !dirty) return Future.value();
    dirty = false;
    return log.flush(standing: _own.length, all: _all);
  }

  /// Writes what changed now, on this thread: as the relay stops.
  void saveNow() {
    final log = _log;
    if (log == null) return;
    log.flushNow(standing: _own.length, all: _all);
    dirty = false;
  }
}
