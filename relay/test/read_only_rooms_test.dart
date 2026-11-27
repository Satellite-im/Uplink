import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/p256.dart';
import 'package:ghost_relay/relay.dart';
import 'package:test/test.dart';

/// Read-only rooms (Matt, 2026-11-20: "read only channels for system messages and admin / moderation announcements"):
/// a circle's read-only space is a room bound to the circle owner's key, where the hub lets only the owner and the
/// admins the owner signed post; a changed app can't put words in front of the other members.

final _rnd = Random(7);
List<int> _bytes(int n) => [for (var i = 0; i < n; i++) _rnd.nextInt(256)];
List<int> _unhex(String s) => [for (var i = 0; i + 1 < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];

/// An install: a key, and connections to the hub signed with it.
class _Install {
  _Install() : scalar = _bytes(32) {
    key = P256.publicOf(scalar);
    id = Hub.nameOf(key);
  }
  final List<int> scalar;
  late final List<int> key;
  late final String id;
  bool closed = false;
  late WebSocket ws;
  final said = StreamController<Map>.broadcast();
  final frames = <List<int>>[];

  /// Signs in (or only looks, with [peek]); what the hub answers the hello with.
  /// The same identity on another device ([device] names it in the hello).
  _Install.copyOf(_Install other)
      : scalar = other.scalar,
        key = other.key,
        id = other.id;

  Future<Map> connect(String url, {bool peek = false, String? device}) async {
    final socket = await WebSocket.connect(url);
    if (!peek) ws = socket;
    socket.done.then((_) => closed = true);
    final first = Completer<Map>(), hello = Completer<Map>();
    socket.listen((d) {
      if (d is List<int>) {
        frames.add(d);
        return;
      }
      final m = jsonDecode(d as String) as Map;
      if (!first.isCompleted) {
        first.complete(m);
      } else if (!hello.isCompleted) {
        hello.complete(m);
      } else {
        said.add(m);
      }
    });
    final nonce = _unhex((await first.future)['hello'] as String);
    final sig = P256.sign(scalar, [...utf8.encode(Hub.greeting), ...nonce], _bytes(32));
    socket.add(jsonEncode({'id': id, 'key': base64Encode(key), 'sig': base64Encode(sig), if (peek) 'peek': true, 'device': ?device}));
    return hello.future.timeout(const Duration(seconds: 5));
  }

  /// A packet to [to], as the app's hub route sends one: [1][seq][to][the packet].
  void sendTo(_Install to, List<int> packet) {
    final seq = ByteData(4)..setUint32(0, _rnd.nextInt(1 << 30));
    ws.add(Uint8List.fromList([Hub.toPeer, ...seq.buffer.asUint8List(), ..._unhex(to.id), ...packet]));
  }
}


Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 200));

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
final _token = 'cd' * 32;
final _base = 'a1' * 16;

void main() {
  late Relay relay;
  late Hub hub;
  late String url;

  setUp(() async {
    hub = Hub();
    relay = Relay(hub: hub);
    url = 'ws://127.0.0.1:${await relay.start(port: 0)}/hub';
  });
  tearDown(() => relay.stop());

  /// The owner's signed admin list of generation [gv] naming [admins], as a manifest carries it.
  Map<String, Object?> grants(_Install owner, int gv, List<_Install> admins) {
    final o = _hex(owner.key);
    final g = {for (final a in admins) a.id: _hex(P256.sign(owner.scalar, Hub.grantMessage(o, a.id), _bytes(32)))};
    return {'gv': gv, 'g': g, 'gs': _hex(P256.sign(owner.scalar, Hub.grantsMessage(o, gv, g), _bytes(32)))};
  }

  String roomOf(_Install owner) => Hub.anchoredName(_unhex(_base), owner.key);
  Map<String, Object?> anchor(_Install owner, [Map<String, Object?> g = const {}]) => {'base': _base, 'owner': _hex(owner.key), ...g};

  void say(_Install who, String room, int kind, List<int> bytes) => who.ws.add(Uint8List.fromList([kind, ..._unhex(room), ...bytes]));

  test('only the owner and the admins they signed post; a member keeps nothing and reaches only the writers', () async {
    final owner = _Install(), admin = _Install(), member = _Install(), other = _Install();
    final room = roomOf(owner);
    final g = grants(owner, 1, [admin]);
    for (final i in [owner, admin, member, other]) {
      await i.connect(url);
    }
    final answers = <String, Map>{};
    for (final i in [owner, admin, member, other]) {
      i.said.stream.listen((m) {
        if (m['room'] == room && m.containsKey('ok')) answers[i.id] = m;
      });
      // The member joins with an old list (no admins): the owner's newer one wins whatever order they come in.
      i.ws.add(jsonEncode({'join': room, 'token': _token, 'ro': anchor(owner, i == member ? const {} : g)}));
      await _settle();
    }
    expect(answers[owner.id]?['ro'], 'writer');
    expect(answers[admin.id]?['ro'], 'writer');
    expect(answers[member.id]?['ro'], 'reader');
    expect(hub.writersIn(room), {owner.id, admin.id});

    final refused = member.said.stream.firstWhere((m) => m['ro'] == 'refused');
    say(member, room, Hub.toRoomKept, [9, 9, 9]);
    await refused.timeout(const Duration(seconds: 3));
    say(member, room, Hub.toRoom, [8, 8]);
    say(admin, room, Hub.toRoomKept, [1, 2, 3]);
    await _settle();
    expect(hub.keptIn('ro:$room'), 1, reason: 'the admin\'s alone');
    List<int> tail(List<int> f, int n) => f.sublist(f.length - n);
    expect(other.frames.map((f) => tail(f, 3)).toList(), [[1, 2, 3]], reason: 'another member never sees the member\'s words');
    expect(owner.frames.map((f) => tail(f, 2)).toList(), anyElement(equals([8, 8])), reason: 'what a member says besides reaches the writers');
    expect(owner.frames.any((f) => tail(f, 3).every((b) => b == 9)), isFalse);
  });

  test('an admin taken away by a newer list may not post; an older list never comes back', () async {
    final owner = _Install(), admin = _Install();
    final room = roomOf(owner);
    await owner.connect(url);
    await admin.connect(url);
    owner.ws.add(jsonEncode({'join': room, 'token': _token, 'ro': anchor(owner, grants(owner, 1, [admin]))}));
    await _settle();
    expect(hub.writersIn(room), {owner.id, admin.id});
    owner.ws.add(jsonEncode({'anchor': room, ...grants(owner, 2, [])}));
    await _settle();
    expect(hub.writersIn(room), {owner.id});
    admin.ws.add(jsonEncode({'join': room, 'token': _token, 'ro': anchor(owner, grants(owner, 1, [admin]))}));
    await _settle();
    expect(hub.writersIn(room), {owner.id}, reason: 'generation 1 is older than 2');
    say(admin, room, Hub.toRoomKept, [5]);
    await _settle();
    expect(hub.keptIn('ro:$room'), 0);
  });

  test('a list not signed by the owner, or a room not made from the owner\'s key, is refused', () async {
    final owner = _Install(), faker = _Install();
    final room = roomOf(owner);
    await faker.connect(url);
    // The faker claims to own the owner's room: its name isn't made from the faker's key.
    final no = faker.said.stream.firstWhere((m) => m['room'] == room);
    faker.ws.add(jsonEncode({'join': room, 'token': _token, 'ro': anchor(faker)..['owner'] = _hex(faker.key)}));
    expect((await no.timeout(const Duration(seconds: 3)))['err'], 'bad anchor');
    // The right owner's key, an admin list the faker signed: joined as a reader, the list passed over.
    final forged = grants(faker, 5, [faker]);
    faker.ws.add(jsonEncode({'join': room, 'token': _token, 'ro': anchor(owner, forged)}));
    await _settle();
    expect(hub.writersIn(room), {owner.id});
    say(faker, room, Hub.toRoomKept, [7]);
    await _settle();
    expect(hub.keptIn('ro:$room'), 0);
  });

  test('a read-only room is apart from an ordinary one of the same name', () async {
    final owner = _Install(), old = _Install(), reader = _Install();
    final room = roomOf(owner);
    await old.connect(url);
    await reader.connect(url);
    old.ws.add(jsonEncode({'join': room, 'token': _token}));
    reader.ws.add(jsonEncode({'join': room, 'token': _token, 'ro': anchor(owner)}));
    await _settle();
    say(old, room, Hub.toRoomKept, [4, 4]);
    await _settle();
    expect(reader.frames, isEmpty, reason: 'joining without ro never reaches the read-only room');
    expect(hub.keptIn(room), 1);
    expect(hub.keptIn('ro:$room'), 0);
  });

  test('anyone in a read-only room may react: kept, to everyone, passed on as a reaction; a big one is dropped', () async {
    final owner = _Install(), member = _Install(), other = _Install();
    final room = roomOf(owner);
    for (final i in [owner, member, other]) {
      await i.connect(url);
      i.ws.add(jsonEncode({'join': room, 'token': _token, 'ro': anchor(owner)}));
      await _settle();
    }
    say(member, room, Hub.toRoomReaction, [3, 3, 3]);
    say(member, room, Hub.toRoomReaction, List.filled(Hub.maxReaction + 1, 6));
    await _settle();
    expect(hub.keptIn('ro:$room'), 1);
    for (final i in [owner, other]) {
      expect(i.frames.length, 1);
      expect(i.frames.single[0], Hub.toRoomReaction, reason: 'passed on as a reaction, for the app to take as nothing else');
      expect(i.frames.single.sublist(17, 33), _unhex(member.id));
    }
    final later = _Install();
    await later.connect(url);
    later.ws.add(jsonEncode({'join': room, 'token': _token, 'ro': anchor(owner)}));
    await _settle();
    expect(later.frames.single[0], Hub.toRoomReaction, reason: 'kept for whoever comes later');
  });
}
