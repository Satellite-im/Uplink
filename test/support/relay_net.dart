import 'dart:async';
import 'dart:io' show SocketException;
import 'dart:math';
import 'dart:typed_data';

import 'package:ghost_messaging/net/hub_link.dart';
import 'package:ghost_relay/federation.dart';
import 'package:ghost_relay/handles.dart';
import 'package:ghost_relay/home_record.dart' show HomeBook;
import 'package:ghost_relay/hub.dart';

import 'hub_pair.dart';

/// Several relays in one process, with nothing between them but memory (docs/OPEN_NETWORK.md, section 4): each a real
/// hub with real federation ([Federation]) and usernames ([Handles]), reached by apps through its own [MemoryHub] and
/// by each other through [fedDial]. No server, no socket, no DNS.
///
///   final net = RelayNet();
///   final a = net.relay('a.test'), b = net.relay('b.test');          // wss://a.test/hub, wss://b.test/hub
///   HubCarrier(url: a.url, signer: …, dial: a.dial);                  // an app on relay a
///   net.relay('old.test', federation: false);                         // a relay from before relays talked
class RelayNet {
  /// [now] is the relays' clock where a test moves it itself; the real one otherwise.
  RelayNet({this.now});
  final DateTime Function()? now;

  /// The relays, by their hub's address.
  final Map<String, MemoryHub> byUrl = {};
  final Map<String, Federation> feds = {};

  /// Addresses at which nothing answers for now, to a relay or to an app.
  final Set<String> down = {};

  /// Every address one relay dialled another at, in order.
  final List<String> dialled = [];

  /// Every address an app dialled itself, apart from its own relay's ([appDial]).
  final List<String> asked = [];
  int _seed = 0;
  final Map<String, int> _seeds = {};

  /// The relay at [host] stopped and started again: the same key (it keeps that in its folder), and nothing of what
  /// it held in memory: nobody connected, no packets kept, no record of where anyone else lives, no usernames (the
  /// test's relays keep those in memory too). Whoever was connected finds their connection gone, and dials again.
  MemoryHub restart(String host, {FedMode mode = FedMode.open}) {
    final was = byUrl['wss://$host/hub']!;
    for (final p in was.pairs) {
      p.cut();
    }
    feds['wss://$host/hub']?.stop();
    final now = relay(host, mode: mode);
    // The apps that dialled the old one dial the same way in: their dial reaches the new hub from now on.
    was.redirect = now;
    return now;
  }

  /// A relay at `wss://<host>/hub`. [mode] is whether it links with other relays; [federation] false makes a hub with
  /// none of it at all, as one from before; [handles] false one that keeps no usernames either.
  /// [names] are the hosts the hub takes a sign-in bound to (relay/lib/hub.dart greetingV2); with none it takes v1
  /// alone, as every relay did before.
  MemoryHub relay(String host, {FedMode mode = FedMode.open, bool federation = true, bool handles = true, Set<String> block = const {}, int? maxOthers, int checksASecond = 1000, Set<String> names = const {}}) {
    final url = 'wss://$host/hub';
    final seed = _seeds[url] ??= ++_seed * 10;
    final fed = federation ? Federation(config: FedConfig(mode: mode, publicHub: url, block: block), dial: fedDial, now: now, random: Random(seed), checksASecond: checksASecond, hellosAMinute: 1000, homes: maxOthers == null ? null : HomeBook(maxOthers: maxOthers)) : null;
    final hub = Hub(handles: handles ? (Handles(random: Random(seed + 1))..load()) : null, federation: fed, random: Random(seed + 2), names: names);
    if (fed != null) feds[url] = fed;
    return byUrl[url] = MemoryHub(hub, url);
  }

  /// How one relay dials another: its end of a connection the other's hub is given the far end of.
  Future<HubSocket> fedDial(Uri url) async {
    dialled.add('$url');
    final to = byUrl['$url'];
    if (to == null || down.contains('$url')) throw const SocketException('nothing answers there');
    final a = _Wire(), b = _Wire();
    a._other = b;
    b._other = a;
    to.hub.attach(b);
    return a;
  }

  /// How an app dials a relay that is not its own, by its address (a name asked of that relay itself).
  Future<HubLink> appDial(String url) async {
    asked.add(url);
    final to = byUrl[url];
    if (to == null || down.contains(url)) throw const SocketException('nothing answers there');
    return to.dial(url);
  }

  /// Lets every relay do what its clock says is due (a relay's own program does this once a second).
  void tick() {
    for (final f in feds.values) {
      f.tick();
    }
  }
}

/// One end of a connection between two relays, held in memory.
class _Wire implements HubSocket {
  final _incoming = StreamController<Object?>();
  late _Wire _other;
  bool _open = true;

  @override
  Stream<Object?> get incoming => _incoming.stream;

  @override
  void add(Object data) {
    if (_open && _other._open) _other._incoming.add(data is String ? data : Uint8List.fromList(data as List<int>));
  }

  @override
  bool get isOpen => _open;

  @override
  Future<void> close([int? code, String? reason]) async {
    _end();
    _other._end();
  }

  void _end() {
    if (!_open) return;
    _open = false;
    _incoming.close();
  }
}
