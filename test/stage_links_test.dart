import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/voice/voice.dart';

// A stage's connections (GMFB-29, from the Uplink gap review: "A stage/stream mode: some people speak, many listen, with
// a listener count"). In a call everyone connects to everyone; on a stage two who both listen have nothing to send each
// other, so they make no connection, and a stage holds many more listeners. Three devices on a stand-in relay: who
// offers to whom is read from each one's log.

class _Hub {
  final Map<String, List<_Route>> rooms = {};
}

class _Route implements VoiceRoute {
  _Route(this.hub, this.me);
  final _Hub hub;
  @override
  final String me;
  final _events = StreamController<RoomEvent>.broadcast();
  final _packets = StreamController<({String room, String from, Uint8List bytes})>.broadcast();
  final _looks = StreamController<({String room, List<String> members})>.broadcast();

  @override
  Future<List<String>> join(String room, String token) async {
    final r = hub.rooms[room] ??= [];
    final others = [for (final o in r) o.me];
    for (final o in r) {
      scheduleMicrotask(() => o._events.add(RoomEvent(room, came: me)));
    }
    r.add(this);
    return others;
  }

  @override
  void leave(String room) => hub.rooms[room]?.remove(this);
  @override
  void send(String room, Uint8List bytes) {
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

class _Media implements VoiceMedia {
  @override
  final ValueNotifier<Map<String, double>> levels = ValueNotifier(const {});
  final offers = <String>[];
  final closed = <String>[];
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
  VoicePeer peer(String id, {required void Function(Map<String, dynamic> candidate) onCandidate}) => _Peer(this, id);
  @override
  void setPeerVolume(String id, double volume) {}
  @override
  void setPeerMuted(String id, bool muted) {}
}

class _Peer implements VoicePeer {
  _Peer(this.media, this.id);
  final _Media media;
  final String id;
  static const _opus = 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\n';
  @override
  Future<String> makeOffer() async {
    media.offers.add(id);
    return _opus;
  }

  @override
  Future<String> takeOffer(String sdp) async => _opus;
  @override
  Future<void> takeAnswer(String sdp) async {}
  @override
  Future<void> addCandidate(Map<String, dynamic> candidate) async {}
  @override
  Future<void> close() async => media.closed.add(id);
}

Future<void> _settle() async {
  for (var i = 0; i < 40; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('on a stage two listeners make no connection; brought up to speak, one connects to the rest', () async {
    final hub = _Hub();
    final c = VoiceChannel.make('Town hall');
    // Ids so the lower one is known: a1 (the speaker), b2 and c3 (listening).
    const host = 'a1', ann = 'b2', bob = 'c3';
    final listening = {ann, bob};
    bool listens(String id) => listening.contains(id);
    final media = {host: _Media(), ann: _Media(), bob: _Media()};
    VoiceSession session(String id) => VoiceSession(channel: c, route: _Route(hub, id), media: media[id]!, name: id)..listens = listens;
    final h = session(host), a = session(ann), b = session(bob);
    await h.join();
    await _settle();
    await a.join();
    await _settle();
    await b.join();
    await _settle();

    expect(media[ann]!.offers, [host], reason: 'Ann offers to the speaker alone');
    expect(media[bob]!.offers, [host], reason: 'Bob too, not to Ann: both listen');
    expect(b.members.keys, containsAll([host, ann]), reason: 'still in the call together');

    // A hand up, said to everyone.
    a.raiseHand(true);
    await _settle();
    expect(h.members[ann]!.hand, isTrue);

    // Ann brought up to speak: she and Bob now connect, the lower id offering, once.
    listening.remove(ann);
    a.raiseHand(false);
    for (final s in [h, a, b]) {
      s.relink();
    }
    await _settle();
    expect(media[ann]!.offers, [host, bob]);
    expect(media[bob]!.offers, [host], reason: 'Bob waits for the offer from the lower id');
    expect(h.members[ann]!.hand, isFalse);

    // Back to the audience: their connection goes.
    listening.add(ann);
    for (final s in [a, b]) {
      s.relink();
    }
    await _settle();
    expect(media[ann]!.closed, contains(bob));
    expect(media[bob]!.closed, contains(ann));
  });

  test('a call that is not a stage connects everyone as before', () async {
    final hub = _Hub();
    final c = VoiceChannel.make('Friday hang');
    final media = {'a1': _Media(), 'b2': _Media(), 'c3': _Media()};
    for (final id in ['a1', 'b2', 'c3']) {
      await VoiceSession(channel: c, route: _Route(hub, id), media: media[id]!, name: id).join();
      await _settle();
    }
    expect(media['c3']!.offers, ['a1', 'b2']);
  });

  // Voice asks relink on every change in a space's call (lib/voice/channels.dart: _enforce). Someone coming in offers to
  // everyone there; the one already in, with the lower id, offered back from relink before that offer arrived, so each
  // held an offer of its own and could take neither (seen in the browser's end-to-end run: no sound, a red mark).
  test('in a space\'s call the one already there makes no offer of its own to whoever comes in, whatever the ids', () async {
    final hub = _Hub();
    final c = VoiceChannel.make('Lounge');
    final media = {'a1': _Media(), 'b2': _Media()};
    VoiceSession session(String id) {
      final s = VoiceSession(channel: c, route: _Route(hub, id), media: media[id]!, name: id)..listens = (_) => false;
      s.addListener(s.relink);
      return s;
    }

    await session('a1').join();
    await _settle();
    await session('b2').join();
    await _settle();
    expect(media['b2']!.offers, ['a1'], reason: 'whoever comes in offers');
    expect(media['a1']!.offers, isEmpty, reason: 'and the one already there answers, offering nothing of its own');
  });

  // From the review of 677fd6dc7: someone whose connection to the relay drops long enough for the hub to say they went
  // comes back by their carrier joining the room again by itself (the room said closed, then who is there). Nobody runs
  // join() again, so the one coming back offers again from that list, marked again.
  test('someone whose relay connection dropped and came back is connected again', () async {
    final hub = _Hub();
    final c = VoiceChannel.make('Lounge');
    final media = {'a1': _Media(), 'b2': _Media()};
    final routes = <String, _Route>{};
    VoiceSession session(String id) {
      final s = VoiceSession(channel: c, route: routes[id] = _Route(hub, id), media: media[id]!, name: id)..listens = (_) => false;
      s.addListener(s.relink);
      return s;
    }

    final a = session('a1');
    await a.join();
    await _settle();
    final b = session('b2');
    await b.join();
    await _settle();
    expect(media['b2']!.offers, ['a1']);
    routes['a1']!._events.add(RoomEvent(c.room, went: 'b2'));
    await _settle();
    expect(media['a1']!.closed, contains('b2'));
    routes['a1']!._events.add(RoomEvent(c.room, came: 'b2'));
    routes['b2']!._events.add(RoomEvent(c.room, closed: true));
    routes['b2']!._events.add(RoomEvent(c.room, members: ['a1']));
    await _settle();
    expect(media['b2']!.offers, ['a1', 'a1'], reason: 'the one coming back offers again');
    expect(media['a1']!.offers, isEmpty);
    expect(a.members.keys, contains('b2'));
    expect(b.joined, isTrue);
  });

  // An app from before 677fd6dc7 already in the call offers back to whoever comes in from relink, when its id is the
  // lower. The newcomer (the browser, always) lets that offer go unanswered; the old app, finding the newcomer's offer,
  // lets its own go and answers (its offer handling, as it was).
  test('a newcomer lets the crossing first offer of an older app with the lower id go unanswered', () async {
    final hub = _Hub();
    final c = VoiceChannel.make('Lounge');
    final old = _Route(hub, 'a1');
    await old.join(c.room, c.token);
    final said = <Map<String, dynamic>>[];
    old.packets.listen((p) => said.add((jsonDecode(utf8.decode(NetCrypto.open(c.key, p.bytes)!)) as Map).cast<String, dynamic>()));
    final media = _Media();
    final b = VoiceSession(channel: c, route: _Route(hub, 'b2'), media: media, name: 'b2')..listens = (_) => false;
    b.addListener(b.relink);
    await b.join();
    await _settle();
    expect(media.offers, ['a1']);
    // The old app's own first offer, crossing.
    old.send(c.room, NetCrypto.seal(c.key, utf8.encode(jsonEncode({'t': 'offer', 'to': 'b2', 'sdp': _Peer._opus, 'j': 'old-join'}))));
    await _settle();
    expect([for (final m in said) if (m['t'] == 'answer') m], isEmpty, reason: 'not answered: the old app answers ours');
    expect(media.closed, isNot(contains('a1')), reason: 'its own offer is kept');
    // A second try marked again is answered as ever.
    old.send(c.room, NetCrypto.seal(c.key, utf8.encode(jsonEncode({'t': 'offer', 'to': 'b2', 'sdp': _Peer._opus, 'j': 'old-join', 'a': 1}))));
    await _settle();
    expect([for (final m in said) if (m['t'] == 'answer') m], hasLength(1));
  });

  // The other side of a crossing: the lower id, with an offer of its own out, gives it up for the higher's and answers.
  test('two first offers that cross: the lower id gives its own up and answers the higher\'s', () async {
    final hub = _Hub();
    final c = VoiceChannel.make('Lounge');
    final other = _Route(hub, 'b2');
    await other.join(c.room, c.token);
    final said = <Map<String, dynamic>>[];
    other.packets.listen((p) => said.add((jsonDecode(utf8.decode(NetCrypto.open(c.key, p.bytes)!)) as Map).cast<String, dynamic>()));
    final media = _Media();
    final a = VoiceSession(channel: c, route: _Route(hub, 'a1'), media: media, name: 'a1')..listens = (_) => false;
    await a.join();
    await _settle();
    expect(media.offers, ['b2']);
    other.send(c.room, NetCrypto.seal(c.key, utf8.encode(jsonEncode({'t': 'offer', 'to': 'a1', 'sdp': _Peer._opus, 'j': 'b2-join'}))));
    await _settle();
    expect([for (final m in said) if (m['t'] == 'answer') m], hasLength(1), reason: 'the higher\'s offer is answered');
    expect(media.closed, contains('b2'), reason: 'its own offer given up');
    await a.leave();
  });

  // A stage: b2 is being brought up to speak while c3 comes in; c3's roster still reads b2 a listener at its join, so it
  // offers nothing to b2, and b2 waits for an offer that never comes. After a moment the lower id offers (the call's
  // mending, VoiceSession._mendAll, here at a test's pace).
  test('two whose stage rosters disagree for a moment as one comes in still connect', () async {
    const quick = MendTimes(every: Duration(milliseconds: 40), first: Duration(milliseconds: 150), second: Duration(milliseconds: 600), finding: Duration(seconds: 5));
    final hub = _Hub();
    final c = VoiceChannel.make('Town hall');
    final media = {'a1': _Media(), 'b2': _Media(), 'c3': _Media()};
    final listeningAt = {
      'a1': {'b2', 'c3'},
      'b2': {'b2', 'c3'},
      'c3': {'b2', 'c3'},
    };
    final sessions = <String, VoiceSession>{};
    VoiceSession session(String id) {
      final s = VoiceSession(channel: c, route: _Route(hub, id), media: media[id]!, name: id, mend: quick)..listens = (x) => listeningAt[id]!.contains(x);
      s.addListener(s.relink);
      return sessions[id] = s;
    }

    await session('a1').join();
    await _settle();
    await session('b2').join();
    await _settle();
    listeningAt['a1']!.remove('b2');
    listeningAt['b2']!.remove('b2');
    sessions['a1']!.relink();
    sessions['b2']!.relink();
    await _settle();
    await session('c3').join();
    await _settle();
    listeningAt['c3']!.remove('b2');
    sessions['c3']!.relink();
    await _settle();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await _settle();
    final b2c3 = media['b2']!.offers.where((x) => x == 'c3').length + media['c3']!.offers.where((x) => x == 'b2').length;
    expect(b2c3, 1, reason: 'b2 and c3 connected once');
    for (final s in sessions.values) {
      await s.leave();
    }
  });
}
