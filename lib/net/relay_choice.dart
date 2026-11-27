/// Using a relay server of one's own (GMFB-25, "Self-hosting the relay, documented", from the Uplink gap review):
/// what a typed address becomes, whether an Uplink relay answers at it before the app moves there, and how the
/// relay in use is named in Settings › Routes. How to run one is docs/SELF_HOSTING.md.
///
/// What a relay of one's own does and doesn't reach (said in Settings › Routes and the docs). Since relays talk to
/// each other (docs/OPEN_NETWORK.md, section 4; lib/net/homes.dart), a friend can be on another relay, where both
/// relays allow it. Usernames, sealed account backups, circles, spaces, calls and invite words still live on the relay
/// they were made on, and reach only people using the same relay. Texts (SMS) don't go through any relay. The
/// Marketplace is always read from Uplink's own relay.
library;

import 'dart:async';
import 'dart:convert';

import '../relay_host/address.dart';
import 'home_record.dart' show goodRelayHost;
import 'hub_carrier.dart' show HubRelay;
import 'hub_link.dart';
import 'net.dart';

/// Whether [url] is Uplink's own relay (gogho.st, or ghost-sms.com from before the move).
bool isOwnRelay(String url) {
  final host = Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
  return host == 'gogho.st' || host == 'ghost-sms.com' || host == 'www.gogho.st';
}

/// The host a link names for the relay at [hubUrl] (an add-me link, lib/friends/add_link.dart): its host, with its
/// port where that is not the scheme's own. Null for Uplink's own (a link that names none means ours), and for
/// a relay nobody elsewhere could dial by a host's name: one hosted from an app, or one at a plain `ws://` address on a
/// local network.
String? relayHostForLinks(String hubUrl) {
  if (hubUrl == Net.defaultHub || isOwnRelay(hubUrl)) return null;
  final u = Uri.tryParse(hubUrl);
  if (u == null || u.scheme != 'wss' || u.host.isEmpty) return null;
  final host = '${u.host.toLowerCase()}${u.hasPort && u.port != 443 ? ':${u.port}' : ''}';
  return goodRelayHost(host) ? host : null;
}

/// The relay in use, in a line for Settings › Routes.
String relayInUseWords(String hubUrl) {
  if (hubUrl == Net.defaultHub) return 'Uplink\'s relay (gogho.st)';
  // A relay hosted from an app (lib/relay_host): this one's own, or someone else's reached over Direct.
  final hosted = GhostRelayAddress.parse(hubUrl);
  if (hosted != null) return hosted.relay == Net.instance.hostedHere ? 'The relay on this device' : 'A relay in someone\'s app (${hosted.relay.substring(0, 8)}), over Direct';
  final u = Uri.tryParse(hubUrl);
  final host = u == null ? hubUrl : '${u.host}${u.hasPort ? ':${u.port}' : ''}';
  if (isOwnRelay(hubUrl)) return 'Uplink\'s relay ($host)';
  return 'Your own relay: $host';
}

/// What a typed address becomes: a WebSocket address ending in /hub. `relay.example.com` is
/// `wss://relay.example.com/hub`; `https://` is `wss://` and `http://` is `ws://`; a path not ending in /hub has /hub
/// put on it; a query or a fragment is dropped. Null where it can't be an address (no host, another scheme, spaces).
/// Empty is empty: Uplink's own again.
String? tidyRelayAddress(String typed) {
  var s = typed.trim();
  if (s.isEmpty) return '';
  if (s.contains(RegExp(r'\s'))) return null;
  // A relay hosted from someone's app (lib/relay_host/address.dart), or the link its keeper shared: its address as
  // written, in lower case, or nothing where it isn't one.
  if (s.toLowerCase().startsWith('ghostmsg://')) s = relayFromLink(s) ?? '';
  if (s.isEmpty) return null;
  if (isGhostRelay(s)) return GhostRelayAddress.parse(s)?.toString();
  if (!s.contains('://')) s = 'wss://$s';
  final Uri u;
  try {
    u = Uri.parse(s);
  } catch (_) {
    return null;
  }
  final scheme = switch (u.scheme.toLowerCase()) {
    'wss' || 'https' => 'wss',
    'ws' || 'http' => 'ws',
    _ => null,
  };
  if (scheme == null || u.host.isEmpty || u.userInfo.isNotEmpty) return null;
  var path = u.path.replaceAll(RegExp(r'/+$'), '');
  if (!path.endsWith('/hub')) path = '$path/hub';
  return Uri(scheme: scheme, host: u.host.toLowerCase(), port: u.hasPort ? u.port : null, path: path).toString();
}

/// What came of asking an address whether it is an Uplink relay.
class RelayCheck {
  const RelayCheck.answered(this.took, {this.relay, this.hosted = false, this.asksPass = false}) : problem = null;
  const RelayCheck.failed(this.problem)
      : took = null,
        relay = null,
        hosted = false,
        asksPass = false;

  /// What the relay said of itself in its greeting (its name, the address it is known by, whether it talks to other
  /// relays); null from a relay from before.
  final HubRelay? relay;

  /// Whether it said it runs in someone's app (relay/lib/hub.dart `hosted`; lib/relay_host), and whether it asks for a
  /// pass phrase (`pass`): said to the person before they move there, and the phrase asked for.
  final bool hosted, asksPass;

  /// Why it isn't usable, in words; null where a relay answered.
  final String? problem;

  /// How long it took to answer.
  final Duration? took;

  bool get ok => problem == null;
}

/// Asks [url] (already tidied) whether an Uplink relay's hub is there: it connects and waits for the hub's
/// greeting (`{"hello": <hex>}`, relay/lib/hub.dart), then closes without signing in. Nothing about this install is
/// sent. A server that answers something else, or nothing within [timeout], is not one. It is dialled with [connect]
/// where one is given (a test's stand-in, or another way to a hub), and with [dialHub]'s WebSocket where not.
Future<RelayCheck> checkRelay(String url, {Duration timeout = const Duration(seconds: 8), HubDial? connect}) async {
  final started = DateTime.now();
  HubLink ws;
  try {
    ws = await (connect ?? dialHub)(url).timeout(timeout);
  } on TimeoutException {
    return const RelayCheck.failed('Nothing answered there in time.');
  } catch (e) {
    return RelayCheck.failed('Couldn\'t connect: ${_short(e)}');
  }
  final greeted = Completer<bool>();
  HubRelay? relay;
  var hosted = false, asksPass = false;
  Map? hello;
  var doorFull = false;
  final sub = ws.said.listen(
    (data) {
      if (greeted.isCompleted) return;
      try {
        final m = data is String ? jsonDecode(data) : null;
        if (m is Map) {
          // A hosted relay's door, full for this device: said so, not taken for something else.
          if (m['door'] == 'full') doorFull = true;
          hello = m;
          relay = HubRelay.from(m['relay']);
          hosted = m['hosted'] == true;
          asksPass = m['pass'] == true;
        }
        greeted.complete(m is Map && m['hello'] is String && RegExp(r'^[0-9a-f]{16,128}$').hasMatch(m['hello'] as String));
      } catch (_) {
        greeted.complete(false);
      }
    },
    onDone: () => greeted.isCompleted ? null : greeted.complete(false),
    onError: (_) => greeted.isCompleted ? null : greeted.complete(false),
    cancelOnError: true,
  );
  final left = timeout - DateTime.now().difference(started);
  final bool ok;
  try {
    ok = await greeted.future.timeout(left.isNegative ? Duration.zero : left);
  } on TimeoutException {
    await _close(ws, sub);
    return const RelayCheck.failed('A server answered there, but not as an Uplink relay.');
  }
  await _close(ws, sub);
  if (doorFull) return const RelayCheck.failed(doorFullWords);
  if (!ok) return const RelayCheck.failed('A server answered there, but not as an Uplink relay.');
  // A hosted relay's address names the relay: the one that answers must be it (found in the second review,
  // 2026-11-23: anything at that node was taken).
  final named = GhostRelayAddress.parse(url);
  if (named != null && (hello == null || !HubRelay.proves(hello!, named))) return RelayCheck.failed(wrongRelayWords);
  return RelayCheck.answered(DateTime.now().difference(started), relay: relay, hosted: hosted, asksPass: asksPass);
}

/// Stops listening and closes the connection, waiting two seconds at most; nothing that goes wrong in it matters.
Future<void> _close(HubLink ws, StreamSubscription<dynamic> sub) async {
  await sub.cancel().catchError((_) {});
  await ws.close().timeout(const Duration(seconds: 2)).catchError((_) {});
}

/// Why a dial failed, in a line to show: its first line, 120 characters at most.
String _short(Object e) {
  final line = dialProblem(e).split('\n').first.trim();
  return line.length > 120 ? '${line.substring(0, 120)}…' : line;
}
