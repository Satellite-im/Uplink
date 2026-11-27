import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'hub.dart';
import 'ws_door.dart';

/// Dialling another relay safely (federation.dart). The addresses this relay dials come from other people: a home
/// record anyone can sign, a name someone typed after an "@", the address another relay says is its own. So before
/// anything is dialled it is held to all of this, and what fails is not dialled at all:
///
/// - `wss://` only; plain `ws://` only where [plain] says so (`GHOST_FED_PLAIN`).
/// - Port 443, and the others named in [ports] (`GHOST_FED_PORTS`), and no more.
/// - A hub's address and nothing else: a host, a path ending `/hub`, no user, query or fragment, 200 characters.
/// - Never an address on this machine or its own network. The name is looked up first, here, and **every** answer
///   must be a public address ([isPublic]): not loopback, private, link-local, unique-local, carrier-grade NAT, a
///   documentation or reserved range, multicast, nor an IPv4 one of those written as IPv6. One private answer among
///   public ones refuses the name. A literal address is held to the same.
/// - Then the connection is made **to the address that was checked**, not to the name: nothing is looked up a second
///   time, so a name can't answer "public" to the check and "127.0.0.1" to the dial. TLS still names the host and
///   checks its certificate; a redirect is not followed anywhere else.
/// - Ten seconds to connect, and so many dials a minute of each kind ([take]): a relay's own ([dialsAMinute]: a link
///   first wanted, a name asked after), its tries again at a relay that could not be reached ([retriesAMinute]), and
///   its looks at an address another relay claims ([lookBacksAMinute]). Each kind has its own, so strangers' hellos
///   can't use up the dials this relay needs for its own people, nor its tries again its first dials.
class DialGuard {
  DialGuard({this.plain = false, Set<int> ports = const {}, Future<List<InternetAddress>> Function(String host)? resolve, DateTime Function()? now, this.dialsAMinute = 30, this.retriesAMinute = 30, this.lookBacksAMinute = 10, this.timeout = const Duration(seconds: 10), this.lookupWithin = const Duration(seconds: 5)})
      : ports = {443, ...ports},
        _resolve = resolve ?? _lookup,
        _now = now ?? DateTime.now;

  /// Whether `ws://` may be dialled.
  final bool plain;

  /// The ports that may be dialled.
  final Set<int> ports;

  /// Dials a minute: this relay's own, its tries again, its looks at another relay's address.
  final int dialsAMinute;
  final int retriesAMinute;
  final int lookBacksAMinute;

  /// How long a connection may take to be made, and a name to be looked up.
  final Duration timeout;
  final Duration lookupWithin;

  /// How a name is looked up (a test's own, else the system's), the clock, and when each dial of the last minute was
  /// made, by kind.
  final Future<List<InternetAddress>> Function(String host) _resolve;
  final DateTime Function() _now;
  final Map<DialKind, List<DateTime>> _dialled = {};

  static Future<List<InternetAddress>> _lookup(String host) => InternetAddress.lookup(host);

  /// How many dials of [kind] a minute are allowed.
  int _most(DialKind kind) => switch (kind) {
        DialKind.own => dialsAMinute,
        DialKind.retry => retriesAMinute,
        DialKind.lookBack => lookBacksAMinute,
      };

  /// The dials of [kind] made within the last minute; older ones are dropped as it is asked.
  List<DateTime> _of(DialKind kind) {
    final now = _now();
    return (_dialled[kind] ??= [])..removeWhere((t) => now.difference(t) >= const Duration(minutes: 1));
  }

  /// Whether a dial of [kind] may be made this minute, and that it is: counted.
  bool take(DialKind kind) {
    final list = _of(kind);
    if (list.length >= _most(kind)) return false;
    list.add(_now());
    return true;
  }

  /// Whether a dial of [kind] may be made this minute, without counting one.
  bool hasRoom(DialKind kind) => _of(kind).length < _most(kind);

  /// Why [url] is not a hub's address this relay may dial, by its words alone (nothing is looked up); null where it is.
  String? shape(Uri url) {
    if (url.scheme != 'wss' && !(plain && url.scheme == 'ws')) return 'only wss:// is dialled';
    if (url.host.isEmpty || url.host.length > 253 || url.userInfo.isNotEmpty || url.hasQuery || url.hasFragment) return 'not a hub\'s address';
    if ('$url'.length > 200 || !url.path.endsWith('/hub')) return 'not a hub\'s address';
    final port = url.hasPort ? url.port : (url.scheme == 'wss' ? 443 : 80);
    if (!ports.contains(port)) return 'port $port is not dialled';
    return null;
  }

  /// The addresses [url] may be dialled at, each one checked, or why it may not be dialled. Whether a dial may be made
  /// this minute is [take]'s, asked first by whoever dials.
  Future<({List<InternetAddress> addresses, String? problem})> check(Uri url) async {
    ({List<InternetAddress> addresses, String? problem}) no(String why) => (addresses: const <InternetAddress>[], problem: why);
    final wrong = shape(url);
    if (wrong != null) return no(wrong);
    final literal = InternetAddress.tryParse(url.host);
    final List<InternetAddress> found;
    if (literal != null) {
      // An IPv4 address written any way but the plain one (a leading zero reads as eight to some, as ten to others)
      // is not dialled: nobody should have to wonder which machine it means.
      if (literal.type == InternetAddressType.IPv4 && literal.rawAddress.join('.') != url.host) return no('not a public address');
      found = [literal];
    } else {
      try {
        found = await _resolve(url.host).timeout(lookupWithin);
      } catch (_) {
        return no('the name could not be looked up');
      }
    }
    if (found.isEmpty) return no('the name could not be looked up');
    if (!found.every(isPublic)) return no('not a public address');
    return (addresses: found, problem: null);
  }

  /// Dials the hub at [url]: checked, then connected to an address that passed. Throws a [DialRefused] where it may
  /// not be dialled, and whatever the connection throws where it can't be made.
  Future<HubSocket> dial(Uri url) async {
    final ok = await check(url);
    if (ok.problem != null) throw DialRefused(ok.problem!);
    Object? last;
    // The first address that answers; each try has the whole ten seconds, and there are at most three.
    for (final address in ok.addresses.take(3)) {
      try {
        return await connectPinned(url, address, timeout: timeout);
      } catch (e) {
        last = e;
      }
    }
    throw last ?? const DialRefused('nothing answered');
  }

  /// Whether [a] is an address on the public internet: none of the ranges that mean "this machine", "this network",
  /// "nowhere" or "everyone".
  static bool isPublic(InternetAddress a) {
    final b = a.rawAddress;
    if (a.type == InternetAddressType.IPv4 && b.length == 4) return _publicV4(b);
    if (a.type != InternetAddressType.IPv6 || b.length != 16) return false;
    bool zero(int from, int to) => b.sublist(from, to).every((x) => x == 0);
    // IPv4 written as IPv6 (::ffff:a.b.c.d), and through a NAT64 gateway (64:ff9b::a.b.c.d): as the IPv4 it is.
    if (zero(0, 10) && b[10] == 0xff && b[11] == 0xff) return _publicV4(b.sublist(12));
    if (b[0] == 0 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b && zero(4, 12)) return _publicV4(b.sublist(12));
    // 6to4 (2002:a.b.c.d::/48) carries an IPv4 address too.
    if (b[0] == 0x20 && b[1] == 0x02) return _publicV4(b.sublist(2, 6));
    // Only global unicast, 2000::/3: that leaves out ::, ::1, fc00::/7 (unique local), fe80::/10 (link-local),
    // fec0::/10, ff00::/8 (multicast) and everything not handed out.
    if ((b[0] & 0xe0) != 0x20) return false;
    // 2001:db8::/32 is for documentation; 2001::/23 is protocol assignments (Teredo and the like), not hosts.
    if (b[0] == 0x20 && b[1] == 0x01 && (b[2] == 0x0d && b[3] == 0xb8 || b[2] < 0x02)) return false;
    return true;
  }

  /// Whether the four bytes [b] are a public IPv4 address: each range left out says what it is.
  static bool _publicV4(List<int> b) {
    final a = b[0], c = b[1];
    if (a == 0 || a == 10 || a == 127 || a >= 224) return false; // this network, private, loopback, multicast and reserved
    if (a == 100 && c >= 64 && c <= 127) return false; // carrier-grade NAT
    if (a == 169 && c == 254) return false; // link-local
    if (a == 172 && c >= 16 && c <= 31) return false; // private
    if (a == 192 && c == 168) return false; // private
    if (a == 192 && c == 0 && (b[2] == 0 || b[2] == 2)) return false; // protocol assignments, documentation
    if (a == 192 && c == 88 && b[2] == 99) return false; // 6to4 relays
    if (a == 198 && (c == 18 || c == 19)) return false; // benchmarking
    if (a == 198 && c == 51 && b[2] == 100) return false; // documentation
    if (a == 203 && c == 0 && b[2] == 113) return false; // documentation
    return true;
  }
}

/// What a dial is for, each kind with its own dials a minute ([DialGuard.take]).
enum DialKind {
  /// A link this relay wants for the first time, or a name asked after.
  own,

  /// A relay that could not be reached, tried again.
  retry,

  /// The address another relay's hello claims, looked at to see the same key there.
  lookBack,
}

/// Why an address was not dialled ([DialGuard.dial]).
class DialRefused implements Exception {
  const DialRefused(this.why);

  /// In words, as [DialGuard.shape] and [DialGuard.check] say it: for the keeper's log.
  final String why;
  @override
  String toString() => why;
}

/// The longest message a link carries, with a margin: a packet passed on (`[5]` or `[6]`, a hub's packet and 53 bytes)
/// or 64 KB of words (federation.dart closes a link past either). One longer, from a hub this relay dialled, ends the
/// connection before a byte of it is held (ws_door.dart); so does a first message (the hub's hello) of more than 16 KB.
const linkMost = 128 << 10;

/// A WebSocket to the hub at [url], made to [address] and nowhere else: the name in [url] is what TLS is asked for and
/// the certificate checked against (with [context]'s roots; the system's where null), and what the request says its
/// host is, but it is never looked up. The handshake is made here (ws_door.dart), asking for no compression, and only a
/// `101` is taken: a redirect anywhere is a refusal. Every message that comes in is held to [linkMost] before it is
/// read. [timeout] is for all of it: connecting, TLS and the handshake.
Future<HubSocket> connectPinned(Uri url, InternetAddress address, {Duration timeout = const Duration(seconds: 10), SecurityContext? context}) async {
  final secure = url.scheme == 'wss';
  final port = url.hasPort ? url.port : (secure ? 443 : 80);
  // The socket as far as it has been made, and whether the time ran out: a connection that finishes after that is
  // destroyed, not left open with nobody holding it.
  Socket? made;
  var late = false;
  Future<WebSocket> connect() async {
    Socket socket = await Socket.connect(address, port, timeout: timeout);
    made = socket;
    if (late) throw const WsRefused('too slow');
    if (secure) {
      socket = await SecureSocket.secure(socket, host: url.host, context: context);
      made = socket;
      if (late) throw const WsRefused('too slow');
    }
    return dialGuarded(socket, url, most: linkMost);
  }

  try {
    final ws = await connect().timeout(timeout);
    ws.pingInterval = const Duration(seconds: 30);
    final socket = made;
    return WebSocketHubSocket(ws, onDone: () => socket?.destroy());
  } catch (_) {
    // Given up on (or refused): whatever it had made by then is let go, now or as soon as it is made.
    late = true;
    made?.destroy();
    rethrow;
  }
}

/// A WebSocket this relay dialled, as a hub connection is held ([HubSocket]).
class WebSocketHubSocket implements HubSocket {
  WebSocketHubSocket(this._ws, {void Function()? onDone}) : _onDone = onDone;
  final WebSocket _ws;

  /// Called once nothing more comes in: [connectPinned] destroys the socket underneath with it.
  final void Function()? _onDone;

  /// What the hub dialled says: text as a String, anything binary as a `Uint8List`.
  @override
  late final Stream<Object?> incoming = _ws.map<Object?>((data) => data is String || data is Uint8List ? data : Uint8List.fromList(data as List<int>)).transform(StreamTransformer.fromHandlers(handleDone: (sink) {
    _onDone?.call();
    sink.close();
  }));
  @override
  void add(Object data) => _ws.add(data);
  @override
  bool get isOpen => _ws.readyState == WebSocket.open;
  @override
  Future<void> close([int? code, String? reason]) => _ws.close(code, reason);
}
