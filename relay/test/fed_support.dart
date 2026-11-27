import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ghost_relay/fed_dial.dart';
import 'package:ghost_relay/federation.dart';
import 'package:ghost_relay/handles.dart';
import 'package:ghost_relay/home_record.dart';
import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/p256.dart';
import 'package:test/test.dart';

/// A hub's answer to a sign-in without its clock ("now", and "since" it started, said with every sign-in: relay/lib/hub.dart),
/// which the tests of everything else it says leave out, as hub_socket_test.dart does; its own test is there.
Map withoutClock(Map answer) => {...answer}
  ..remove('now')
  ..remove('since');

/// What the federation tests stand on (federation_test.dart and the rest): relays that are real hubs with real
/// federation, a made-up internet between them that is nothing but memory, installs that sign in as an app does, and
/// one clock for all of it that only moves when a test moves it. Nothing here waits on a timer or a socket.

final _rnd = Random(22);
List<int> someBytes(int n) => [for (var i = 0; i < n; i++) _rnd.nextInt(256)];
List<int> unhex(String s) => [for (var i = 0; i + 1 < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];

/// One end of a connection held in memory: what it is told ([add]) the other end hears a moment later, in order, and
/// either end closing it closes both.
class MemSocket implements HubSocket {
  final _incoming = StreamController<Object?>();
  late MemSocket other;
  bool _open = true;

  /// What this end was closed with, where it was this end that closed it.
  int? code;
  String? reason;

  /// Everything this end was told by the other, for a test to read: text as maps, frames as bytes.
  final List<Object> heard = [];

  static (MemSocket, MemSocket) pair() {
    final a = MemSocket(), b = MemSocket();
    a.other = b;
    b.other = a;
    return (a, b);
  }

  @override
  Stream<Object?> get incoming => _incoming.stream;

  @override
  void add(Object data) {
    if (!_open || !other._open) return;
    final carried = data is String ? data : Uint8List.fromList(data as List<int>);
    Object read = carried;
    if (carried is String) {
      try {
        read = jsonDecode(carried) as Object;
      } catch (_) {}
    }
    other.heard.add(read);
    other._incoming.add(carried);
  }

  @override
  bool get isOpen => _open;

  @override
  Future<void> close([int? code, String? reason]) async {
    if (!_open) return;
    this.code = code;
    this.reason = reason;
    _end();
    other._end();
  }

  /// Dropped, as a network going does: nothing said, no number.
  void drop() {
    _end();
    other._end();
  }

  void _end() {
    if (!_open) return;
    _open = false;
    _incoming.close();
  }
}

/// A made-up internet: hubs by their address, a clock, and every dial made over it.
class FakeNet {
  FakeNet([DateTime? at]) : clock = at ?? DateTime.utc(2026, 11, 22, 12);

  /// The time, for every relay on it. It moves only when a test moves it ([pass]).
  DateTime clock;
  DateTime now() => clock;

  final Map<String, Hub> hubs = {};
  final Map<String, TestRelay> relays = {};

  /// Addresses at which nothing answers for now.
  final Set<String> down = {};

  /// Every address dialled, in order, those that failed too.
  final List<String> dialled = [];

  /// Every connection made, by the address dialled: the dialler's end.
  final Map<String, List<MemSocket>> made = {};

  /// Hubs played by hand, by their address: each is given its end of every connection dialled to it.
  final Map<String, void Function(MemSocket theirs)> hand = {};

  /// Addresses whose dials are under way until the test lets them finish.
  final Map<String, Completer<void>> held = {};

  /// What a relay is given to dial with.
  Future<HubSocket> dial(Uri url) async {
    dialled.add('$url');
    final wait = held['$url'];
    if (wait != null) await wait.future;
    final hub = hubs['$url'], played = hand['$url'];
    if ((hub == null && played == null) || down.contains('$url')) throw const SocketException('nothing answers there');
    final (mine, theirs) = MemSocket.pair();
    (made['$url'] ??= []).add(mine);
    played == null ? hub!.attach(theirs) : played(theirs);
    return mine;
  }

  /// Moves the clock on by [d] and lets every relay do what is then due, then lets what that started finish.
  Future<void> pass(Duration d) async {
    clock = clock.add(d);
    await settle();
  }

  /// Lets everything said so far be heard and answered, and every relay do what is due now.
  Future<void> settle() async {
    await pumpEventQueue();
    for (final r in relays.values) {
      r.fed.tick();
    }
    await pumpEventQueue();
  }

  /// Cuts every connection made to [url], as a network going does.
  void cut(String url) {
    for (final s in made[url] ?? const <MemSocket>[]) {
      s.drop();
    }
  }
}

/// A relay on the made-up internet: a hub with usernames and federation, at `wss://<host>/hub` unless it has no address.
class TestRelay {
  /// [shipped] makes every limit not named the one the relay ships with, where the default here is generous for what
  /// a test is not about: a test of a contest for a shared allowance asks for it.
  TestRelay(this.net, this.host, {FedMode mode = FedMode.open, Set<String> allow = const {}, Set<String> block = const {}, bool public = true, String via = '', bool standingOpen = false, Set<String> standing = const {}, int seed = 1, int? packetsAMinute, int? bytesADay, int? lookupsAnHour, int? queuePackets, int? queueBytes, int? queuedBytes, int? maxLinks, int? maxPeers, int? checksAnHour, int? checksASecond, int? hellosAMinute, int? recordsAMinute, int? newRelaysAnHour, int? dialsAMinute, int? retriesAMinute, int? lookBacksAMinute, Directory? dataDir, int? maxOwn, int? maxOthers, int heldBytes = 96 << 20, bool fed = true, bool shipped = false, Directory? hubData}) {
    const d = FedConfig();
    int pick(int? given, int generous, int ships) => given ?? (shipped ? ships : generous);
    this.fed = Federation(
      dataDir: dataDir,
      config: FedConfig(mode: mode, allow: allow, block: block, publicHub: public ? url : '', via: via, packetsAMinute: packetsAMinute ?? d.packetsAMinute, bytesADay: bytesADay ?? d.bytesADay, lookupsAnHour: lookupsAnHour ?? d.lookupsAnHour, standingOpen: standingOpen, standing: standing),
      dial: net.dial,
      guard: DialGuard(now: net.now, dialsAMinute: pick(dialsAMinute, 1000, 30), retriesAMinute: pick(retriesAMinute, 1000, 30), lookBacksAMinute: pick(lookBacksAMinute, 1000, 10)),
      now: net.now,
      random: Random(seed),
      queuePackets: queuePackets ?? 2000,
      queueBytes: queueBytes ?? 16 << 20,
      queuedBytes: queuedBytes ?? 32 << 20,
      maxLinks: maxLinks ?? 64,
      maxPeers: maxPeers ?? 256,
      checksAnHour: checksAnHour ?? 600,
      checksASecond: pick(checksASecond, 1000, 20),
      hellosAMinute: pick(hellosAMinute, 1000, 30),
      recordsAMinute: recordsAMinute ?? 240,
      newRelaysAnHour: pick(newRelaysAnHour, 1000, 8),
      homes: dataDir == null ? HomeBook(maxOwn: maxOwn ?? 20000, maxOthers: maxOthers ?? 10000, now: net.now) : null,
    );
    handles = Handles(now: net.now, random: Random(seed + 100))..load();
    hub = Hub(now: net.now, random: Random(seed + 200), handles: handles, federation: fed ? this.fed : null, heldBytes: heldBytes, dataDir: hubData, keepHeld: hubData != null);
    if (public) net.hubs[url] = hub;
    net.relays[host] = this;
  }

  final FakeNet net;
  final String host;
  late final Federation fed;
  late final Handles handles;
  late final Hub hub;

  String get url => 'wss://$host/hub';
  String get id => fed.id;
}

/// An install: a key, and a connection to a relay's hub signed with it, as an app makes one.
class Install {
  Install() : scalar = someBytes(32) {
    key = P256.publicOf(scalar);
    id = Hub.nameOf(key);
  }
  final List<int> scalar;
  late final List<int> key;
  late final String id;

  /// Its newest connection: this install's end of it.
  late MemSocket socket;

  /// The hub's hello, what it answered the sign-in with, what it said after, and the packets it handed over.
  late Map hello;
  late Map signedIn;
  final said = <Map>[];
  final frames = <List<int>>[];

  int _seq = 0;
  int _count = 0;

  /// Signs in to [relay]'s hub: the hub's number, signed with this install's key.
  Future<Map> signIn(TestRelay relay, {String? device, String from = ''}) => signInTo(relay.hub, device: device, from: from);

  /// Signs in to [hub] itself, one not on the made-up internet.
  Future<Map> signInTo(Hub hub, {String? device, String from = ''}) async {
    final (mine, theirs) = MemSocket.pair();
    socket = mine;
    final first = Completer<Map>(), second = Completer<Map>();
    mine.incoming.listen((d) {
      if (d is List<int>) {
        frames.add(d);
        return;
      }
      final m = jsonDecode(d as String) as Map;
      if (!first.isCompleted) {
        first.complete(m);
      } else if (!second.isCompleted) {
        second.complete(m);
      } else {
        said.add(m);
      }
    });
    hub.attach(theirs, from: from);
    hello = await first.future;
    final sig = P256.sign(scalar, [...utf8.encode(Hub.greeting), ...unhex(hello['hello'] as String)], someBytes(32));
    mine.add(jsonEncode({'id': id, 'key': base64Encode(key), 'sig': base64Encode(sig), 'device': ?device}));
    signedIn = withoutClock(await second.future.timeout(const Duration(seconds: 5)));
    return signedIn;
  }

  /// Goes, as an app closing does.
  void leave() => socket.drop();

  /// A packet to [to], as the app's hub route sends one: `[1][number][to][the packet]`. The number it was given.
  int send(String to, List<int> packet) {
    final n = ++_seq;
    socket.add(Uint8List.fromList([Hub.toPeer, ...(ByteData(4)..setUint32(0, n)).buffer.asUint8List(), ...unhex(to), ...packet]));
    return n;
  }

  void say(Map<String, Object?> what) => socket.add(jsonEncode(what));

  /// The hub's answer to packet [n], once it has one.
  Map? answerTo(int n) => said.where((m) => m['ack'] == n || m['nak'] == n).firstOrNull;

  /// A home record of this install's saying it lives at [addresses], signed with its own key: record number [n]
  /// where given, else one more than the last it made.
  Map<String, Object> record(List<String> addresses, {int? n, DateTime? at}) => homeRecord(scalar, addresses, n: n ?? ++_count, at: at ?? DateTime.utc(2026, 11, 22, 11));

  /// Gives [relay]'s hub this install's own record naming [relay], over its connection there.
  Future<Map<String, Object>> giveHome(TestRelay relay, {int? n}) async {
    final rec = record([relay.url], n: n);
    say({'dir': 'home', 'rec': rec});
    await pumpEventQueue();
    return rec;
  }

  /// Claims [name] as its username on the relay it is signed in to.
  Future<void> claim(String name) async {
    say({'dir': 'claim', 'name': name});
    await pumpEventQueue();
    expect(said.last, containsPair('ok', true), reason: 'the username was not claimed');
  }
}

/// A home record for the key [scalar], signed with it, as the app makes one.
Map<String, Object> homeRecord(List<int> scalar, List<String> addresses, {int n = 1, DateTime? at, List<int>? signWith}) {
  final key = P256.publicOf(scalar);
  final a = Hub.nameOf(key);
  final t = (at ?? DateTime.utc(2026, 11, 22, 11)).millisecondsSinceEpoch;
  final sig = P256.sign(signWith ?? scalar, HomeRecord.signedBytes(a: a, n: n, t: t, h: addresses), someBytes(32));
  return {'v': 1, 'a': a, 'k': base64Encode(key), 'h': addresses, 'n': n, 't': t, 's': base64Encode(sig)};
}

/// The frame a hub hands an app for a packet from [from]: `[1][from][the packet]`.
List<int> handed(String from, List<int> packet) => [Hub.toPeer, ...unhex(from), ...packet];

/// Another relay played by hand: a key, and a link to a real relay's hub over which a test says exactly what it
/// likes, as a relay that does not keep the rules would.
class HandRelay {
  HandRelay({List<int>? scalar}) : scalar = scalar ?? someBytes(32) {
    key = P256.publicOf(this.scalar);
    id = Hub.nameOf(key);
  }
  final List<int> scalar;
  late final List<int> key;
  late final String id;

  /// Its end of the link, the hub's hello to it, the number it made up, and what the relay answered its hello with.
  late MemSocket socket;
  late Map hello;
  late List<int> c;
  late Map answer;

  /// What the relay said after that, and the frames it sent.
  final said = <Map>[];
  final frames = <List<int>>[];
  int _n = 0;

  /// Dials [to]'s hub and says hello as a relay does, claiming [url] where given, signing that it dialled [to]'s own
  /// address. What it is answered: the relay's yes or no, or `{"closed": true}` where it only closed. [sayId], [sayKey],
  /// [signWith], [signedFor], [signedUrl], [signedNonce], [signedDialled] and [signedStay] say or sign something other
  /// than the truth.
  Future<Map> link(TestRelay to, {String? url, bool stay = false, List<int>? signWith, String? sayId, List<int>? sayKey, String? signedFor, String? signedUrl, List<int>? signedNonce, String? signedDialled, bool? signedStay}) async {
    final (mine, theirs) = MemSocket.pair();
    socket = mine;
    final first = Completer<Map>(), second = Completer<Map>();
    mine.incoming.listen((d) {
      if (d is List<int>) {
        frames.add(d);
        return;
      }
      final m = jsonDecode(d as String) as Map;
      if (!first.isCompleted) {
        first.complete(m);
      } else if (!second.isCompleted) {
        second.complete(m);
      } else {
        said.add(m);
      }
    }, onDone: () {
      if (!second.isCompleted) second.complete({'closed': true});
    });
    to.hub.attach(theirs);
    hello = await first.future;
    c = someBytes(32);
    final theirs_ = (hello['relay'] as Map?)?['id'] as String? ?? '00' * 16;
    dialled = to.url;
    final sig = P256.sign(signWith ?? scalar, Federation.dialBytes(nonce: signedNonce ?? unhex(hello['hello'] as String), dialler: id, answerer: signedFor ?? theirs_, c: c, dialled: signedDialled ?? dialled, url: signedUrl ?? url ?? '', stay: signedStay ?? stay), someBytes(32));
    mine.add(jsonEncode({'fed': 1, 'id': sayId ?? id, 'key': base64Encode(sayKey ?? key), 'sig': base64Encode(sig), 'url': ?url, 'c': [for (final b in c) b.toRadixString(16).padLeft(2, '0')].join(), if (stay) 'stay': true}));
    return answer = await second.future.timeout(const Duration(seconds: 5));
  }

  /// The address it dialled, as it signed it.
  late String dialled;

  /// Whether the relay's yes was signed by the key its hub's hello named, over this relay's number, both names and the
  /// address dialled.
  bool get answerProven {
    final card = hello['relay'] as Map;
    try {
      return answer['ok'] == true && answer['id'] == card['id'] && P256.verify(base64Decode(card['key'] as String), Federation.answerBytes(c: c, dialler: id, answerer: card['id'] as String, dialled: dialled), base64Decode(answer['sig'] as String));
    } catch (_) {
      return false;
    }
  }

  /// Passes [packet] on as from [from] to [to]: a `[5]`, or a `[6]` naming [relay]. The number it was given.
  int send(String to, String from, List<int> packet, {String? relay}) {
    final n = ++_n;
    socket.add(Uint8List.fromList([relay == null ? Federation.toRelay : Federation.toRelayVia, ...(ByteData(4)..setUint32(0, n)).buffer.asUint8List(), ...unhex(to), ...unhex(from), if (relay != null) ...unhex(relay), ...packet]));
    return n;
  }

  void say(Map<String, Object?> what) => socket.add(jsonEncode(what));
  Map? answerTo(int n) => said.where((m) => m['ack'] == n || m['nak'] == n).firstOrNull;
}

/// A data folder holding a relay's key already: a relay started in it has this key, so a test can speak as it.
Directory folderWithKey(List<int> scalar) {
  final dir = Directory.systemTemp.createTempSync('ghost-fed-test-');
  addTearDown(() => dir.deleteSync(recursive: true));
  File('${dir.path}/relay-key.json').writeAsStringSync(jsonEncode({'v': 1, 'scalar': [for (final b in scalar) b.toRadixString(16).padLeft(2, '0')].join()}));
  return dir;
}
