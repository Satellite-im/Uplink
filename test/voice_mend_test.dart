import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/voice/voice.dart';

/// A call mends itself (Matt, 2026-11-23: "add better reconnect logic to calls it seems like they can get hung up if
/// one person leaves or a new person joins everyone needs to re connect"). Each test is one way a call used to be left
/// with people in it who could not hear each other until they left and came back:
/// - a device's connection to the relay dropping for a moment (everyone else lets go of it, and nothing was offered
///   again), and the relay itself restarting under everyone;
/// - a connection that was working and broke;
/// - an answer that never arrived;
/// - two offers that crossed (with relink offering only to those a stage held apart, the mending's lower id goes first
///   and one offer is made; crossings themselves, the higher id's standing, are stage_links_test's and
///   voice_mixed_builds_test's);
/// - an older build on the other side, which never offers again by itself.

/// The relay's rooms, with a way to cut one device off and bring it back as the carrier does (lib/net/hub_carrier.dart:
/// `closed` to the one cut off, `went` to the rest; then the room joined again by itself, its members said to the one
/// back and `came` to the rest).
class _Hub {
  final Map<String, List<_Route>> rooms = {};

  /// Said in the room and not passed on, where this answers true: an offer or an answer lost on its way.
  bool Function(String from, Map<String, dynamic> what)? lose;
  Uint8List? key;
}

class _Route implements VoiceRoute {
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
      if (o.me != me) scheduleMicrotask(() => o._events.add(RoomEvent(room, came: me)));
    }
    return others;
  }

  @override
  void leave(String room) {
    final r = hub.rooms[room];
    if (r == null || !r.remove(this)) return;
    for (final o in r) {
      scheduleMicrotask(() => o._events.add(RoomEvent(room, went: me)));
    }
  }

  /// This device's connection to the relay drops.
  void cut(String room) {
    _cut.add(room);
    leave(room);
    _events.add(RoomEvent(room, closed: true));
  }

  /// And comes back: the room is joined again without the call asking.
  Future<void> back(String room) async {
    _cut.remove(room);
    final there = await join(room, '');
    _events.add(RoomEvent(room, members: there));
  }

  @override
  void send(String room, Uint8List bytes) {
    if (_cut.contains(room)) throw StateError('not in that room');
    final lose = hub.lose;
    if (lose != null) {
      final what = (jsonDecode(utf8.decode(NetCrypto.open(hub.key!, bytes)!)) as Map).cast<String, dynamic>();
      if (lose(me, what)) return;
    }
    for (final o in [...?hub.rooms[room]]) {
      if (!identical(o, this)) scheduleMicrotask(() => o._packets.add((room: room, from: me, bytes: bytes)));
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

/// WebRTC stood in for. A connection is through once it has both descriptions (it made an offer and took the answer,
/// or took an offer), until the test breaks it; it says what it was asked to do.
class _Media implements VoiceMedia, LinkedMedia {
  @override
  final ValueNotifier<Map<String, double>> levels = ValueNotifier(const {});
  final log = <String>[];
  final Map<String, _Peer> peers = {};

  @override
  bool? linkUp(String id) => peers[id]?.up;

  /// The connection to [id] breaks: as WebRTC says "failed" and lets go of it.
  void breakLink(String id) => peers.remove(id);

  int count(String what) => log.where((l) => l == what).length;

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
  VoicePeer peer(String id, {required void Function(Map<String, dynamic> candidate) onCandidate}) => peers[id] = _Peer(this, id);
  @override
  void setPeerVolume(String id, double volume) {}
  @override
  void setPeerMuted(String id, bool muted) {}
}

class _Peer implements VoicePeer {
  _Peer(this.media, this.id);
  final _Media media;
  final String id;
  bool up = false, offered = false, closed = false;
  static const _opus = 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\n';

  @override
  Future<String> makeOffer() async {
    offered = true;
    media.log.add('offer to $id');
    return _opus;
  }

  @override
  Future<String> takeOffer(String sdp) async {
    // As WebRTC refuses: an offer can't be taken by a connection that has made one of its own.
    if (offered) throw StateError('have-local-offer');
    if (closed) throw StateError('closed');
    media.log.add('answer $id');
    up = true;
    return _opus;
  }

  @override
  Future<void> takeAnswer(String sdp) async {
    if (!offered || up) throw StateError('no offer waiting');
    media.log.add('took answer from $id');
    up = true;
  }

  @override
  Future<void> addCandidate(Map<String, dynamic> candidate) async {}
  @override
  Future<void> close() async {
    closed = true;
    up = false;
    if (identical(media.peers[id], this)) media.peers.remove(id);
  }
}

/// Waits until [ok] holds, or five seconds go by: never a fixed sleep, which a busy machine outruns.
Future<void> _until(bool Function() ok, [String what = '']) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!ok() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ok(), isTrue, reason: what);
}

/// Quick to mend, so a test waits milliseconds for what a call waits seconds for.
const _quick = MendTimes(every: Duration(milliseconds: 10), first: Duration(milliseconds: 30), second: Duration(milliseconds: 150), finding: Duration(milliseconds: 120));

/// A build from before mending: it looks at nothing and offers nothing again.
const _never = MendTimes(every: Duration(days: 1), first: Duration(days: 1), second: Duration(days: 1), finding: Duration(days: 1));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Hub hub;
  late VoiceChannel c;
  final media = <String, _Media>{};
  final routes = <String, _Route>{};
  final sessions = <String, VoiceSession>{};

  VoiceSession session(String id, {MendTimes mend = _quick}) {
    media[id] = _Media();
    routes[id] = _Route(hub, id);
    return sessions[id] = VoiceSession(channel: c, route: routes[id]!, media: media[id]!, name: id, mend: mend);
  }

  /// Every pair that should be connected is, both ways.
  bool allThrough() {
    for (final a in sessions.keys) {
      for (final b in sessions.keys) {
        if (a != b && media[a]!.linkUp(b) != true) return false;
      }
    }
    return true;
  }

  setUp(() {
    hub = _Hub();
    c = VoiceChannel.make('Lounge');
    hub.key = c.key;
    media.clear();
    routes.clear();
    sessions.clear();
  });

  tearDown(() async {
    for (final s in sessions.values) {
      await s.leave();
    }
  });

  test('a device cut off from the relay for a moment is connected to everyone again when it is back', () async {
    for (final id in ['a', 'b', 'c']) {
      await session(id).join();
    }
    await _until(allThrough, 'the call as it starts');

    routes['b']!.cut(c.room);
    // Everyone else is told b went and lets go of it; b knows it is out of the room.
    await _until(() => media['a']!.linkUp('b') == null && media['c']!.linkUp('b') == null, 'a and c let go of b');
    expect(sessions['b']!.reconnecting, isTrue);
    expect(media['a']!.linkUp('c'), isTrue, reason: 'the others stay connected to each other');

    await routes['b']!.back(c.room);
    await _until(allThrough, 'b connected to a and c again, with nobody leaving the call');
    expect(sessions['b']!.reconnecting, isFalse);
    expect(sessions['a']!.members.keys.toSet(), {'b', 'c'});
    expect(sessions['b']!.members.keys.toSet(), {'a', 'c'});
  });

  test('the relay restarting under everyone: each comes back in turn, and all are connected again', () async {
    for (final id in ['a', 'b', 'c']) {
      await session(id).join();
    }
    await _until(allThrough, 'the call as it starts');

    for (final id in ['a', 'b', 'c']) {
      routes[id]!.cut(c.room);
    }
    await _until(() => sessions.values.every((s) => s.reconnecting), 'everyone knows the relay is gone');
    for (final id in ['c', 'a', 'b']) {
      await routes[id]!.back(c.room);
    }
    await _until(allThrough, 'everyone connected again');
    for (final id in sessions.keys) {
      expect(sessions[id]!.members.keys.toSet(), {'a', 'b', 'c'}..remove(id));
    }
  });

  test('a connection that was working and broke is made again, offered by one side alone', () async {
    await session('a').join();
    await session('b').join();
    await _until(allThrough, 'the call as it starts');
    final before = media['a']!.count('offer to b') + media['b']!.count('offer to a');

    media['a']!.breakLink('b');
    media['b']!.breakLink('a');
    await _until(allThrough, 'connected again');
    // The lower id has the first go, and the other answers: they never both offer.
    expect(media['a']!.count('offer to b') + media['b']!.count('offer to a'), before + 1);
    expect(media['a']!.log.last, 'took answer from b');
  });

  test('an answer that never arrives: the offer is made again', () async {
    await session('a').join();
    var lost = 0;
    hub.lose = (from, what) => what['t'] == 'answer' && lost++ == 0;
    await session('b').join();
    await _until(allThrough, 'connected once the offer was made again');
    expect(lost, greaterThan(0), reason: 'the first answer was lost');
    expect(media['b']!.count('offer to a'), 2);
  });

  // Both find the connection gone and look again at once: relink makes no offer of its own (it connects only those a
  // stage held apart), and the mending's lower id goes first, so one offer is made and answered. Two offers that really
  // cross (the higher's stands) are stage_links_test's.
  test('both quick to look again after the connection broke: one offer, answered, connected', () async {
    await session('a').join();
    await session('b').join();
    await _until(allThrough, 'the call as it starts');

    // Both find the connection gone at once, and both are quick to offer (each as if it had the first go).
    media['a']!.breakLink('b');
    media['b']!.breakLink('a');
    sessions['a']!.relink();
    sessions['b']!.relink();
    await _until(allThrough, 'connected, not failed both ways');
    expect(media['b']!.log.last, 'answer a');
    expect(media['a']!.log.last, 'took answer from b');
  });

  test('with an older build on the lower side, which never offers again, the other side does', () async {
    await session('a', mend: _never).join();
    await session('b').join();
    await _until(allThrough, 'the call as it starts');

    media['a']!.breakLink('b');
    media['b']!.breakLink('a');
    await _until(allThrough, 'b offered after a had its turn and did nothing');
    expect(media['b']!.log.last, 'took answer from a');
  });

  test('someone leaving, and someone new coming in, leave everyone else connected', () async {
    for (final id in ['a', 'b', 'c']) {
      await session(id).join();
    }
    await _until(allThrough, 'the call as it starts');
    final offers = media['a']!.count('offer to b') + media['b']!.count('offer to a');

    await sessions.remove('c')!.leave();
    media.remove('c');
    await _until(() => !sessions['a']!.members.containsKey('c') && !sessions['b']!.members.containsKey('c'), 'c gone for both');
    await session('d').join();
    await _until(allThrough, 'd connected to a and b');
    // Long enough for a mend to have come round several times.
    await Future<void>.delayed(_quick.second * 2);
    expect(media['a']!.count('offer to b') + media['b']!.count('offer to a'), offers, reason: 'a and b were never made to connect again');
    expect(allThrough(), isTrue);
  });
}
