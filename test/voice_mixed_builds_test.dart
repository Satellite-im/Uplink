// This build's calls against the builds already out (from the review of the web branch, 2026-11-23): lib/voice/voice.dart
// against 0.12.18's and 0.12.19's, copied as they were released into test/support/voice_builds/ (0.12.19 settles
// crossed offers the other way round: the lower id's stands). Two of them in a space's call, in every order and either
// id; each cut from the relay and back; mending offers that cross; three of mixed builds. WebRTC is stood in for
// strictly: a connection is through only when an offer and the answer made for exactly that offer have each other's
// descriptions and neither is closed, so two answerers (or two offerers) never count. Times run at a fiftieth of real
// ones and are said in real seconds; the bounds are wide (this Mac is busy) but each is well under what the case took
// before its fix (HEAD with 0.12.19 in with the lower id: 20 s; two mending offers crossing: never; a break noticed 7 s
// apart: 36 s).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/voice/voice.dart' as cur;
import 'support/voice_builds/voice_0_12_18.dart' as v18;
import 'support/voice_builds/voice_0_12_19.dart' as v19;

class _Hub {
  final Map<String, List<_Route>> rooms = {};
  Uint8List? key;
  bool Function(String from, Map<String, dynamic> what)? lose;
  final log = <String>[];
}

/// One way across the relay, in test milliseconds (a fiftieth): 2 ms is 100 ms real.
var latency = 0;
void _deliver(void Function() f) => latency == 0 ? scheduleMicrotask(f) : Timer(Duration(milliseconds: latency), f);

class _Route implements cur.VoiceRoute, v18.VoiceRoute, v19.VoiceRoute {
  _Route(this.hub, this.me);
  final _Hub hub;
  @override
  final String me;
  final _events = StreamController<RoomEvent>.broadcast();
  final _packets = StreamController<({String room, String from, Uint8List bytes})>.broadcast();
  final _looks = StreamController<({String room, List<String> members})>.broadcast();
  final Set<String> _cut = {};

  @override
  Future<List<String>> join(String room, String token) async {
    final r = hub.rooms[room] ??= [];
    final others = [for (final o in r) o.me];
    r.add(this);
    for (final o in r) {
      if (o.me != me) _deliver(() => o._events.add(RoomEvent(room, came: me)));
    }
    return others;
  }

  @override
  void leave(String room) {
    final r = hub.rooms[room];
    if (r == null || !r.remove(this)) return;
    for (final o in r) {
      _deliver(() => o._events.add(RoomEvent(room, went: me)));
    }
  }

  void cut(String room) {
    _cut.add(room);
    leave(room);
    _events.add(RoomEvent(room, closed: true));
  }

  Future<void> back(String room) async {
    _cut.remove(room);
    final there = await join(room, '');
    _events.add(RoomEvent(room, members: there));
  }

  @override
  void send(String room, Uint8List bytes) {
    if (_cut.contains(room)) throw StateError('not in that room');
    final what = (jsonDecode(utf8.decode(NetCrypto.open(hub.key!, bytes)!)) as Map).cast<String, dynamic>();
    if (what['t'] == 'offer' || what['t'] == 'answer') hub.log.add('$me ${what['t']}${what['a'] == 1 ? '(a)' : ''} -> ${what['to']}');
    if (hub.lose?.call(me, what) ?? false) return;
    for (final o in [...?hub.rooms[room]]) {
      if (!identical(o, this)) _deliver(() => o._packets.add((room: room, from: me, bytes: bytes)));
    }
  }

  @override
  void look(String room, String token) {}
  @override
  void unlook(String room) {}
  @override
  Stream<RoomEvent> get events => _events.stream;
  @override
  Stream<({String room, String from, Uint8List bytes})> get packets => _packets.stream;
  @override
  Stream<({String room, List<String> members})> get looks => _looks.stream;
}

final Map<int, _Peer> _all = {};
var _serial = 0;

class _Media implements cur.VoiceMedia, v18.VoiceMedia, v19.VoiceMedia, cur.LinkedMedia, v19.LinkedMedia {
  _Media(this.me);
  final String me;
  @override
  final ValueNotifier<Map<String, double>> levels = ValueNotifier(const {});
  final Map<String, _Peer> peers = {};
  int offers = 0;

  /// Until when this side still reads its connection to an id as through after it broke (it notices late).
  final Map<String, DateTime> blindUntil = {};

  @override
  bool? linkUp(String id) {
    final b = blindUntil[id];
    if (b != null && DateTime.now().isBefore(b)) return true;
    final p = peers[id];
    if (p == null || p.closed) return null;
    return p.through;
  }

  bool through(String id) => linkUp(id) == true;

  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  set muted(bool on) {}
  @override
  set deafened(bool on) {}
  @override
  Future<void> setVideo(bool on) async {}
  @override
  _Peer peer(String id, {required void Function(Map<String, dynamic> candidate) onCandidate}) => peers[id] = _Peer(this, id);
  @override
  void setPeerVolume(String id, double volume) {}
  @override
  void setPeerMuted(String id, bool muted) {}
}

class _Peer implements cur.VoicePeer, v18.VoicePeer, v19.VoicePeer {
  _Peer(this.media, this.id) : serial = ++_serial {
    _all[serial] = this;
  }
  final _Media media;
  final String id;
  final int serial;
  bool offered = false, closed = false;
  int? remote;

  bool get through {
    final r = remote == null ? null : _all[remote!];
    return r != null && !r.closed && r.remote == serial;
  }

  @override
  Future<String> makeOffer() async {
    if (closed) throw StateError('closed');
    offered = true;
    media.offers++;
    return 'v=0\r\no=$serial\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\n';
  }

  @override
  Future<String> takeOffer(String sdp) async {
    if (offered) throw StateError('have-local-offer');
    if (closed) throw StateError('closed');
    remote = int.parse(RegExp(r'o=(\d+)').firstMatch(sdp)!.group(1)!);
    return 'v=0\r\no=$serial\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\n';
  }

  @override
  Future<void> takeAnswer(String sdp) async {
    if (!offered || remote != null) throw StateError('no offer waiting');
    final from = int.parse(RegExp(r'o=(\d+)').firstMatch(sdp)!.group(1)!);
    // An answer made for another offer than this one's is refused (a fingerprint that doesn't match).
    if (_all[from]?.remote != serial) throw StateError('answer for another offer');
    remote = from;
  }

  @override
  Future<void> addCandidate(Map<String, dynamic> candidate) async {}
  @override
  Future<void> close() async {
    closed = true;
    if (identical(media.peers[id], this)) media.peers.remove(id);
  }
}

/// A fiftieth of the real times: every 2 s → 40 ms, first 3 s → 60, second 10 s → 200, finding 15 s → 300.
const _scale = 50;
const _curTimes = cur.MendTimes(every: Duration(milliseconds: 40), first: Duration(milliseconds: 60), second: Duration(milliseconds: 200), finding: Duration(milliseconds: 300));
const _v19Times = v19.MendTimes(every: Duration(milliseconds: 40), first: Duration(milliseconds: 60), second: Duration(milliseconds: 200), finding: Duration(milliseconds: 300));

enum Build { head, v18, v19 }

class _Member {
  _Member(this.build, this.session, this.media, this.route);
  final Build build;
  final dynamic session;
  final _Media media;
  final _Route route;
  Future<void> join() => session.join() as Future<void>;
  Future<void> leave() => session.leave() as Future<void>;
}

late _Hub hub;
const _seed = 'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';
final members = <String, _Member>{};

String get room => cur.VoiceChannel(seed: _seed, name: 'Lounge').room;

/// [space]: as in a space's call, relink asked on every change (lib/voice/channels.dart _enforce).
_Member make(String id, Build b, {bool space = true, cur.MendTimes? curTimes, v19.MendTimes? v19Times}) {
  final r = _Route(hub, id), m = _Media(id);
  dynamic s;
  switch (b) {
    case Build.head:
      final x = cur.VoiceSession(channel: cur.VoiceChannel(seed: _seed, name: 'Lounge'), route: r, media: m, name: id, mend: curTimes ?? _curTimes);
      if (space) {
        x.listens = (_) => false;
        x.addListener(x.relink);
      }
      s = x;
    case Build.v18:
      final x = v18.VoiceSession(channel: v18.VoiceChannel(seed: _seed, name: 'Lounge'), route: r, media: m, name: id);
      if (space) {
        x.listens = (_) => false;
        x.addListener(x.relink);
      }
      s = x;
    case Build.v19:
      final x = v19.VoiceSession(channel: v19.VoiceChannel(seed: _seed, name: 'Lounge'), route: r, media: m, name: id, mend: v19Times ?? _v19Times);
      if (space) {
        x.listens = (_) => false;
        x.addListener(x.relink);
      }
      s = x;
  }
  return members[id] = _Member(b, s, m, r);
}

bool allThrough() {
  for (final a in members.keys) {
    for (final b in members.keys) {
      if (a != b && !members[a]!.media.through(b)) return false;
    }
  }
  return true;
}

/// How long until everyone is through, in real seconds (scaled); null if not within [within] real seconds.
Future<double?> healed({double within = 60}) async {
  final start = DateTime.now();
  final end = start.add(Duration(milliseconds: (within * 1000 / _scale).round()));
  while (!allThrough() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  if (!allThrough()) return null;
  return DateTime.now().difference(start).inMicroseconds * _scale / 1e6;
}

int offers() => members.values.fold(0, (n, m) => n + m.media.offers);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    latency = const int.fromEnvironment('LAT', defaultValue: 2);
    hub = _Hub()..key = cur.VoiceChannel(seed: _seed, name: 'Lounge').key;
    members.clear();
  });
  tearDown(() async {
    for (final m in members.values) {
      await m.leave();
    }
  });

  final results = <String>[];
  tearDownAll(() => debugPrint('\n=== results ===\n${results.join('\n')}'));

  for (final first in Build.values) {
    for (final second in Build.values) {
      if (first == second && first != Build.head) continue;
      // Two released builds together are theirs to settle (0.12.18 with 0.12.19 takes up to 30 s, and 0.12.18 throws
      // taking an answer it has no offer for): not this build's, not run here.
      if (first != Build.head && second != Build.head) continue;
      for (final lowerFirst in [true, false]) {
        final inId = lowerFirst ? 'a' : 'b', newId = lowerFirst ? 'b' : 'a';
        final name = '${first.name} in as $inId, ${second.name} comes in as $newId (space)';
        test(name, () async {
          await make(inId, first).join();
          await Future<void>.delayed(const Duration(milliseconds: 5));
          await make(newId, second).join();
          final t = await healed();
          final before = offers();
          // Twenty real seconds more: nothing should offer again (no loop, no flapping).
          await Future<void>.delayed(Duration(milliseconds: (20 * 1000 / _scale).round()));
          final extra = offers() - before;
          results.add('$name: ${t == null ? 'NEVER' : '${t.toStringAsFixed(1)} s'}, offers after: $extra, still through: ${allThrough()}  [${hub.log.join('; ')}]');
          expect(t, isNotNull, reason: 'connected');
          expect(t!, lessThan(8), reason: 'at once, or after a moment\'s giving way: not after a mend');
          expect(extra, 0, reason: 'no loop');
          expect(allThrough(), isTrue);
        });
      }
    }
  }

  // Relay drop and back, each build cut, against each other build.
  for (final cutB in Build.values) {
    for (final other in Build.values) {
      if (cutB != Build.head && other != Build.head) continue;
      for (final cutLower in [true, false]) {
        final cutId = cutLower ? 'a' : 'b', otherId = cutLower ? 'b' : 'a';
        final name = '${cutB.name} as $cutId cut from the relay and back, ${other.name} as $otherId stays';
        test(name, () async {
          await make(otherId, other).join();
          await Future<void>.delayed(const Duration(milliseconds: 5));
          await make(cutId, cutB).join();
          expect(await healed(), isNotNull, reason: 'the call as it starts');
          members[cutId]!.route.cut(room);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          hub.log.clear();
          await members[cutId]!.route.back(room);
          final t = await healed();
          results.add('$name: ${t == null ? 'NEVER' : '${t.toStringAsFixed(1)} s'}  [${hub.log.join('; ')}]');
          expect(t, isNotNull);
        });
      }
    }
  }

  // Two HEAD builds whose mends offer again at the same moment (their failures were seen ~7 s apart, so the higher's
  // 10 s turn lands on the lower's 3 s one): both offers marked a, each always answered.
  test('head vs head: two mending offers (a) that cross', () async {
    await make('a', Build.head).join();
    await make('b', Build.head, curTimes: const cur.MendTimes(every: Duration(milliseconds: 40), first: Duration(milliseconds: 60), second: Duration(milliseconds: 60), finding: Duration(milliseconds: 300))).join();
    expect(await healed(), isNotNull);
    hub.log.clear();
    members['a']!.media.peers['b']!.closed = true;
    members['a']!.media.peers.remove('b');
    members['b']!.media.peers['a']!.closed = true;
    members['b']!.media.peers.remove('a');
    final t = await healed();
    results.add('head vs head, crossing a-offers: ${t == null ? 'NEVER' : '${t.toStringAsFixed(1)} s'} [${hub.log.join('; ')}]');
    expect(t, isNotNull);
    expect(t!, lessThan(8), reason: 'healed by the first mend, not a later one');
  });

  // Three in a space: a 0.12.19 and a 0.12.18 already in, a browser (HEAD) comes in with the highest id.
  test('v19 a + v18 b in, head c comes in', () async {
    await make('a', Build.v19).join();
    await make('b', Build.v18).join();
    expect(await healed(), isNotNull);
    hub.log.clear();
    await make('c', Build.head).join();
    final t = await healed();
    results.add('v19 a + v18 b, head c: ${t == null ? 'NEVER' : '${t.toStringAsFixed(1)} s'} [${hub.log.join('; ')}]');
    expect(t, isNotNull);
    expect(t!, lessThan(8));
  });

  // Realistic crossing: the connection breaks; b (higher, 10 s turn) notices at once, a (lower, 3 s turn) 7 s later, so
  // both mending offers (a) go at about 10 s and cross.
  test('head vs head: the break noticed 7 s apart, mending offers cross', () async {
    await make('a', Build.head).join();
    await make('b', Build.head).join();
    expect(await healed(), isNotNull);
    hub.log.clear();
    members['a']!.media.blindUntil['b'] = DateTime.now().add(Duration(milliseconds: (7 * 1000 / _scale).round()));
    for (final x in [('a', 'b'), ('b', 'a')]) {
      members[x.$1]!.media.peers[x.$2]!.closed = true;
      members[x.$1]!.media.peers.remove(x.$2);
    }
    final t = await healed(within: 120);
    results.add('head vs head, break seen 7 s apart: ${t == null ? 'NEVER' : '${t.toStringAsFixed(1)} s'} [${hub.log.join('; ')}]');
    expect(t, isNotNull);
    expect(t!, lessThan(14), reason: 'healed by the first mending round');
  });

  // The stage race (review probe 2, adapted): b2 brought up to speak as c3 comes in; c3's roster catches up later.
  test('stage: rosters disagree for a moment as c3 comes in', () async {
    final listeningAt = {'a1': {'b2', 'c3'}, 'b2': {'b2', 'c3'}, 'c3': {'b2', 'c3'}};
    _Member stageMember(String id) {
      final m = make(id, Build.head, space: false);
      final s = m.session as cur.VoiceSession;
      s.listens = (x) => listeningAt[id]!.contains(x);
      s.addListener(s.relink);
      return m;
    }

    await stageMember('a1').join();
    await stageMember('b2').join();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    listeningAt['a1']!.remove('b2');
    listeningAt['b2']!.remove('b2');
    (members['a1']!.session as cur.VoiceSession).relink();
    (members['b2']!.session as cur.VoiceSession).relink();
    await stageMember('c3').join();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    listeningAt['c3']!.remove('b2');
    (members['c3']!.session as cur.VoiceSession).relink();
    final start = DateTime.now();
    while (!(members['b2']!.media.through('c3') && members['c3']!.media.through('b2')) && DateTime.now().difference(start).inMilliseconds < 1200) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    final ok = members['b2']!.media.through('c3') && members['c3']!.media.through('b2');
    final t = DateTime.now().difference(start).inMicroseconds * _scale / 1e6;
    results.add('stage race: ${ok ? '${t.toStringAsFixed(1)} s' : 'NEVER'}; b2-a1 ${members['b2']!.media.through('a1')}, c3-a1 ${members['c3']!.media.through('a1')}');
    expect(ok, isTrue);
  });

  // From the last review: a crossed offer kept for a moment ([_keep]) is not answered once a stage has put both in the
  // audience within that moment; two listeners make no connection.
  test('a kept offer is not answered once the stage holds the two apart', () async {
    var stage = false;
    final a = make('a', Build.v19);
    (a.session as dynamic).listens = (String _) => stage;
    await a.join();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final b = make('b', Build.head);
    (b.session as dynamic).listens = (String _) => stage;
    await b.join();
    // b keeps a's crossing offer; before it gives way (30 ms here) both become listeners on a stage.
    await Future<void>.delayed(const Duration(milliseconds: 8));
    stage = true;
    (a.session as dynamic).relink();
    (b.session as dynamic).relink();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(b.media.peers.containsKey('a'), isFalse, reason: 'no connection between two listeners');
  });
}
