import 'dart:convert';
import 'dart:typed_data';

import 'crypto.dart';
import 'hub_carrier.dart' show NetSigner;

/// A home record: where an account lives, signed by the account (docs/OPEN_NETWORK.md, section 1; Matt, 2026-11-22:
/// "I'd like the relays to be able to talk to each other"). It is what lets two people whose apps use different
/// relays be friends: each relay passes a packet on to the relay the other's record names, and believes nothing else
/// about where anyone lives. An account makes its own, gives it to its relay as it signs in, and tells its friends;
/// moving to another relay is signing one with the next count.
///
///     {"v":1, "a": account name, "k": public key (33 bytes, base64), "h": [1 to 3 relay addresses],
///      "n": a count that only goes up, "t": made (ms), "s": signature (r then s, base64)}
///
/// What is signed ([signedBytes]): the words `ghost-home v1` and a newline, then the name (16 bytes), the count (4
/// bytes, big end first), the time (8 bytes), how many addresses (1 byte), and each address as its length (1 byte)
/// and its bytes. The relay checks the same bytes (relay/lib/home_record.dart), and both are held to
/// test/home_record_vectors.json.
class HomeRecord {
  HomeRecord._(this.a, this.k, this.h, this.n, this.t, this.s);

  /// The account's name (NetCrypto.idOf its key).
  final String a;

  /// The account's public key, 33 bytes.
  final Uint8List k;

  /// Where it lives, as it wrote them: a hub's address (`wss://host/hub`), or a relay hosted from an app's
  /// (`ghost-relay://<relay name>?n=<node id>&via=<the public relay it stays linked to>`).
  final List<String> h;

  /// The count: of two records for one account the higher is the one believed.
  final int n;

  /// When it was made, in milliseconds.
  final int t;

  /// The account's signature over [signedBytes]: r then s, 64 bytes.
  final Uint8List s;

  static const words = 'ghost-home v1\n';
  static const maxAddresses = 3;
  static const maxAddress = 200;
  static const maxCount = 0xffffffff;

  /// The furthest ahead of this device's clock a record's time may be.
  static const ahead = Duration(minutes: 5);

  /// How long a record is good for, from its time: after it, it says nothing, so a relay someone left can't speak for
  /// them by an old record they signed (relay/lib/home_record.dart, the same). An account makes a new one well before
  /// (lib/net/homes.dart).
  static const goodFor = Duration(days: 30);

  /// When it stops being good, in milliseconds.
  int get ends => t + goodFor.inMilliseconds;

  /// Which of two records for one account is believed: above nothing where it is [x]. The higher count; of two with
  /// one count, the later made; of two made at the same moment too, the greater signature, byte by byte. The relay
  /// orders them the same (relay/lib/home_record.dart), and both are held to test/home_record_vectors.json.
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

  static final _hex32 = RegExp(r'^[0-9a-f]{32}$');

  /// Whether [s] could be an address in a record: not empty, no longer than [maxAddress], printable ASCII with no
  /// space in it.
  static bool _plain(String s) => s.isNotEmpty && s.length <= maxAddress && s.codeUnits.every((c) => c > 0x20 && c < 0x7f);

  /// What an account signs to say it lives at [h], as record number [n], made at [t].
  static Uint8List signedBytes({required String a, required int n, required int t, required List<String> h}) {
    final out = BytesBuilder()
      ..add(utf8.encode(words))
      ..add(NetCrypto.unhex(a))
      ..add([(n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff])
      // Eight bytes, big end first, without 64-bit arithmetic (a browser has none): a time is below 2^53, so the first
      // byte is always nothing.
      ..add([0, (t ~/ 0x1000000000000) & 0xff, (t ~/ 0x10000000000) & 0xff, (t ~/ 0x100000000) & 0xff, (t ~/ 0x1000000) & 0xff, (t ~/ 0x10000) & 0xff, (t ~/ 0x100) & 0xff, t & 0xff])
      ..addByte(h.length);
    for (final address in h) {
      final bytes = ascii.encode(address);
      out
        ..addByte(bytes.length)
        ..add(bytes);
    }
    return out.toBytes();
  }

  /// A record saying [signer]'s account lives at [addresses], as its record number [count], signed with its key.
  static Future<HomeRecord> make(NetSigner signer, {required List<String> addresses, required int count, DateTime? now}) async {
    if (addresses.isEmpty || addresses.length > maxAddresses || !addresses.every(_plain)) throw ArgumentError('not addresses a home record can hold');
    if (count < 1 || count > maxCount) throw ArgumentError('not a count a home record can hold');
    final t = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final h = List<String>.unmodifiable(addresses);
    final s = await signer.sign(signedBytes(a: signer.id, n: count, t: t, h: h));
    return HomeRecord._(signer.id, signer.publicKey, h, count, t, s);
  }

  /// The record [json] is, where every part of it is as the plan lays it out, it is still good, and the signature is
  /// the account's own; null where it is not. [forId] and [forKey] (base64) hold it to one account: a friend's record
  /// must be that friend's.
  static HomeRecord? check(Object? json, {DateTime? now, String? forId, String? forKey}) {
    if (json is! Map || json['v'] != 1) return null;
    final a = json['a'], k = json['k'], h = json['h'], n = json['n'], t = json['t'], s = json['s'];
    if (a is! String || k is! String || h is! List || s is! String || k.length > 64 || s.length > 128) return null;
    if (forId != null && a != forId) return null;
    final Uint8List key, sig;
    try {
      key = base64Decode(k);
      sig = base64Decode(s);
    } catch (_) {
      return null;
    }
    if (!_hex32.hasMatch(a) || key.length != 33 || sig.length != 64 || NetCrypto.idOf(key) != a) return null;
    if (forKey != null && base64Encode(key) != forKey) return null;
    if (h.isEmpty || h.length > maxAddresses || !h.every((x) => x is String && _plain(x))) return null;
    if (n is! int || n < 1 || n > maxCount) return null;
    if (t is! int || t < 0 || t > 0x1fffffffffffff) return null;
    final at = now ?? DateTime.now();
    if (t > at.add(ahead).millisecondsSinceEpoch) return null;
    if (at.millisecondsSinceEpoch >= t + goodFor.inMilliseconds) return null;
    final addresses = List<String>.unmodifiable(h.cast<String>());
    if (!NetCrypto.verify(key, signedBytes(a: a, n: n, t: t, h: addresses), sig)) return null;
    return HomeRecord._(a, key, addresses, n, t, sig);
  }

  Map<String, Object> toJson() => {'v': 1, 'a': a, 'k': base64Encode(k), 'h': h, 'n': n, 't': t, 's': base64Encode(s)};

  /// Whether it names [address] (a hub's, as [canonicalHub] writes it, or a hosted relay's as it was written).
  bool names(String address) => h.any((x) => x == address || canonicalHub(x) == address);

  /// The relay it names first, as a person reads it: the host of a hub's address (`relay.example.com`), or for a relay
  /// hosted from an app the public relay it is reached through. Empty where it names nothing readable.
  String get relayHost => h.map(hostOfHome).firstWhere((x) => x.isNotEmpty, orElse: () => '');
}

/// A hub's address as two relays compare them: `wss` or `ws`, the host in lower case, the port only where it is not
/// the scheme's own, the path without a slash at its end, and nothing else. Null where [address] is not a hub's
/// address. The relay writes the same (relay/lib/home_record.dart).
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

/// The address of a relay hosted from an app, named [relay], that stays linked to the public relay at [via].
String hostedAddress(String relay, String via) => 'ghost-relay://$relay?via=${Uri.encodeQueryComponent(via)}';

/// The host a home record's address is read as: a hub's own (with its port where it is not the usual one), or for a
/// hosted relay's the host of the relay it stays linked to. Empty where it has neither.
String hostOfHome(String address) {
  final Uri u;
  try {
    u = Uri.parse(address);
  } catch (_) {
    return '';
  }
  if (u.scheme == 'ghost-relay') {
    final via = u.queryParameters['via'];
    return via == null ? '' : hostOfHome(via);
  }
  if (canonicalHub(address) == null) return '';
  final usual = u.scheme == 'wss' ? 443 : 80;
  return u.hasPort && u.port != usual ? '${u.host}:${u.port}' : u.host;
}

/// A username as it is added: `maya`, or `maya@relay.example` for someone on another relay, with or without an `@` in
/// front. The name in lower case, and the relay's host where one was written.
({String name, String? relay}) splitUsername(String typed) {
  var s = typed.trim().toLowerCase();
  while (s.startsWith('@')) {
    s = s.substring(1);
  }
  final at = s.indexOf('@');
  if (at < 0) return (name: s, relay: null);
  return (name: s.substring(0, at), relay: s.substring(at + 1));
}

final _relayHost = RegExp(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+(:[0-9]{1,5})?$');

/// Whether [host] could be a relay's host as it is written after a username's `@`: a name with a dot in it, and a
/// port where it has one.
bool goodRelayHost(String host) => host.length <= 120 && _relayHost.hasMatch(host);

/// The hub's address a relay's [host] names: `wss://relay.example/hub`.
String? hubOfHost(String host) => goodRelayHost(host) ? canonicalHub('wss://$host/hub') : null;

/// Whether [host] (as written after a username's `@`) is one this app will dial to ask a name of: held to the relay's
/// own rules for what it dials (relay/lib/fed_dial.dart; found in the review, 2026-11-23): the usual port (443) and no
/// other, a name on the internet (not one of the names kept for a machine's own network, like `.local` or
/// `.internal`), and never an address on this machine or its network written as numbers. Typed or pasted text is
/// someone else's choice: `x@192.168.1.1:22` is not dialled.
bool dialableRelayHost(String host) {
  if (!goodRelayHost(host)) return false;
  final colon = host.lastIndexOf(':');
  final name = colon < 0 ? host : host.substring(0, colon);
  if (colon >= 0 && host.substring(colon + 1) != '443') return false;
  const kept = ['localhost', 'local', 'internal', 'intranet', 'lan', 'home', 'corp', 'localdomain', 'arpa', 'private'];
  final last = name.split('.').last;
  if (kept.contains(last) || name == 'localhost') return false;
  // Written as numbers: only an address on the public internet.
  if (RegExp(r'^[0-9.]+$').hasMatch(name)) {
    try {
      return publicIPv4(Uri.parseIPv4Address(name));
    } catch (_) {
      return false;
    }
  }
  return true;
}

/// Whether the four bytes [b] are an IPv4 address on the public internet: none of the ranges for this machine, a
/// private network, link-local, carrier NAT, documentation, multicast or reserved (relay/lib/fed_dial.dart's own).
bool publicIPv4(List<int> b) {
  if (b.length != 4) return false;
  final a = b[0], c = b[1];
  if (a == 0 || a == 10 || a == 127 || a >= 224) return false;
  if (a == 100 && c >= 64 && c <= 127) return false;
  if (a == 169 && c == 254) return false;
  if (a == 172 && c >= 16 && c <= 31) return false;
  if (a == 192 && c == 168) return false;
  if (a == 192 && c == 0 && (b[2] == 0 || b[2] == 2)) return false;
  if (a == 192 && c == 88 && b[2] == 99) return false;
  if (a == 198 && (c == 18 || c == 19)) return false;
  if (a == 198 && c == 51 && b[2] == 100) return false;
  if (a == 203 && c == 0 && b[2] == 113) return false;
  return true;
}
