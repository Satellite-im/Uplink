/// The addresses a relay hosted from the app is reached by (docs/OPEN_NETWORK.md, sections 1 and 5; Matt, 2026-11-22:
/// "i'd like everyone to be able to host a relay from their client"). Nothing here dials or runs anything: it is what
/// the relay picker (Settings › Routes) and the host's own screen read and write, on every platform, a browser too.
///
/// - **Its own address**, `ghost-relay://<relay name>?n=<node id>&via=<the public relay it stays linked to>`: the
///   relay's name is made from its key as an install's is (relay/lib/federation.dart); `n` is the device it runs on
///   on the direct network, where it can be reached over Direct (a hub connection on channel 1:
///   lib/net/p2p/node.dart); `via` is the public relay it stays linked to. What a home record names for its people
///   (lib/net/home_record.dart, hostedAddress), and what the relay picker takes: the app it runs in dials it in memory,
///   anyone else over Direct by `n`.
/// - **On the same network**, `ws://<address>:<port>/hub`: a plain WebSocket, as any relay's hub.
/// - **A link to open**, `ghostmsg://relay?a=<either of those>`: what the QR code holds and what is shared, which opens
///   the app at "Use this relay?" (lib/ui/relay_host_section.dart, askToUseRelay).
library;

import '../net/home_record.dart' show canonicalHub;

/// A relay hosted from someone's app, as its address names it.
class GhostRelayAddress {
  const GhostRelayAddress({required this.relay, this.node, this.via});

  static const scheme = 'ghost-relay';

  /// The relay's name: 32 hex digits.
  final String relay;

  /// The device it runs on, on the direct network (64 hex digits): where it can be reached over Direct. Null where the
  /// address says none (a home record's, or one for the app it runs in).
  final String? node;

  /// The public relay it stays linked to, as hubs' addresses are compared ([canonicalHub]); null where it names none.
  final String? via;

  static final _relay = RegExp(r'^[0-9a-f]{32}$'), _node = RegExp(r'^[0-9a-f]{64}$');

  /// What [text] names, where it is a hosted relay's address: the relay's name in lower case, a node id where `n` is
  /// one, and `via` where it is a hub's address. Null for anything else, a `n` or `via` that is not what it says
  /// included: an address handed around is someone else's to write.
  static GhostRelayAddress? parse(String text) {
    final s = text.trim();
    if (s.length > 400 || !s.toLowerCase().startsWith('$scheme://')) return null;
    final Uri u;
    try {
      u = Uri.parse(s);
    } catch (_) {
      return null;
    }
    final relay = u.host.toLowerCase();
    if (!_relay.hasMatch(relay) || u.hasPort || u.userInfo.isNotEmpty || (u.path.isNotEmpty && u.path != '/')) return null;
    final Map<String, String> q;
    try {
      q = u.queryParameters;
    } catch (_) {
      return null;
    }
    final n = q['n']?.toLowerCase(), v = q['via'];
    if (n != null && !_node.hasMatch(n)) return null;
    final via = v == null ? null : canonicalHub(v);
    if (v != null && (via == null || !via.endsWith('/hub'))) return null;
    return GhostRelayAddress(relay: relay, node: n, via: via);
  }

  /// The same relay, with [node] (or none) and [via] in place of its own.
  GhostRelayAddress withNode(String? node) => GhostRelayAddress(relay: relay, node: node, via: via);

  /// The host a v2 sign-in is bound to (lib/net/hub_carrier.dart, hostOf): the device's node id where the address
  /// names one, which the direct network's own handshake proves (a relay in the middle, claiming this one's name,
  /// would be dialled at a node of its own, and a sign-in made for it is no use here); else the relay's name, for the
  /// app it runs in, which dials it in memory.
  String get signedHost => node ?? relay;

  @override
  String toString() {
    final q = [if (node != null) 'n=$node', if (via != null) 'via=${Uri.encodeQueryComponent(via!)}'];
    return '$scheme://$relay${q.isEmpty ? '' : '?${q.join('&')}'}';
  }

  @override
  bool operator ==(Object other) => other is GhostRelayAddress && other.relay == relay && other.node == node && other.via == via;

  @override
  int get hashCode => Object.hash(relay, node, via);
}

/// Said where a hosted relay's address named one relay and another answered.
const wrongRelayWords = 'Another relay answered there, not the one this address names.';

/// Whether [text] is a hosted relay's address at all (and so not a WebSocket's).
bool isGhostRelay(String text) => text.trim().toLowerCase().startsWith('${GhostRelayAddress.scheme}://');

/// A hub's address on the local network: `ws://<address>:<port>/hub`, an IPv6 address in brackets.
String lanHubUrl(String address, int port) => 'ws://${address.contains(':') ? '[$address]' : address}:$port/hub';

/// The link that opens the app at "Use this relay?" for [address] (a hosted relay's own, or one on the local network):
/// what the host's QR code holds, and what it shares.
String relayLink(String address) => 'ghostmsg://relay?a=${Uri.encodeQueryComponent(address)}';

/// The relay's address a [relayLink] carries, where [text] is one and what it carries is a relay a link may name: a
/// hosted relay's own address, or a plain WebSocket on the local network ([isLocalNetworkHub]); null for anything else.
/// Any other relay, a public `wss://` one included, is taken only typed in (found in the second review, 2026-11-23: a
/// link could name any relay, and on Android a relay that says it doesn't know the account makes the app forget the
/// account's words and keys, lib/account/account.dart, Account.check; a link is not to be enough for that).
String? relayFromLink(String text) {
  final s = text.trim();
  if (!s.toLowerCase().startsWith('ghostmsg://relay')) return null;
  final String? a;
  try {
    a = Uri.parse(s).queryParameters['a'];
  } catch (_) {
    return null;
  }
  if (a == null) return null;
  final hosted = GhostRelayAddress.parse(a);
  if (hosted != null) return '$hosted';
  final hub = canonicalHub(a);
  return hub != null && hub.endsWith('/hub') && isLocalNetworkHub(hub) ? hub : null;
}

/// Whether [url] is a plain WebSocket (`ws://`) to an address on a local network: a private IPv4 range (10/8,
/// 172.16/12, 192.168/16), this device (127/8, ::1), an IPv6 unique-local address (fc00::/7), or a name ending in
/// `.local`.
bool isLocalNetworkHub(String url) {
  final Uri u;
  try {
    u = Uri.parse(url);
  } catch (_) {
    return false;
  }
  if (u.scheme != 'ws') return false;
  final host = u.host.toLowerCase();
  if (host.endsWith('.local') && host.length > '.local'.length) return true;
  final v4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(host);
  if (v4 != null) {
    final b = [for (var i = 1; i <= 4; i++) int.parse(v4.group(i)!)];
    if (b.any((x) => x > 255)) return false;
    return b[0] == 10 || b[0] == 127 || (b[0] == 172 && b[1] >= 16 && b[1] < 32) || (b[0] == 192 && b[1] == 168);
  }
  if (host.contains(':')) {
    final h = host.replaceAll(RegExp(r'[\[\]]'), '');
    return h == '::1' || RegExp(r'^f[cd][0-9a-f]{0,2}:').hasMatch(h);
  }
  return false;
}
