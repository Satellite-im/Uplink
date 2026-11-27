import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart';

/// Welcome messages, the welcome space and read-only spaces (Matt, 2026-11-20: "add - Welcome messages for new members
/// and allow setting a "welcome" channel as well as read only channels for system messages and admin / moderation
/// announcements"): what the circle's manifest says, who may post, the room bound to the owner's key, what a member's
/// app drops, and the system space's notes.

Future<CircleManifest> _sign(CircleManifest m, NetKeys k) => m.signedBy(k.id, k.public, (b) async => NetCrypto.sign(k, b));

/// A route that knows read-only rooms: what was joined (and with what), and packets to hand in.
class _Route implements VoiceRoute, ReadOnlyRoute {
  _Route(this.me);
  @override
  final String me;
  final joins = <({String room, Map<String, Object?>? ro})>[];
  final left = <String>[];
  final anchors = <({String room, Map<String, Object?> grants})>[];
  final _packets = StreamController<({String room, String from, Uint8List bytes})>.broadcast();
  final said = <({String room, Uint8List bytes})>[];

  void hand(String room, String from, List<int> key, Map<String, Object?> what) =>
      _packets.add((room: room, from: from, bytes: NetCrypto.seal(key, utf8.encode(jsonEncode(what)))));

  @override
  Future<List<String>> join(String room, String token) async {
    joins.add((room: room, ro: null));
    return const [];
  }

  @override
  Future<List<String>> joinReadOnly(String room, String token, Map<String, Object?> ro) async {
    joins.add((room: room, ro: ro));
    return const [];
  }

  @override
  void anchor(String room, Map<String, Object?> grants) => anchors.add((room: room, grants: grants));
  @override
  void leave(String room) => left.add(room);
  @override
  void send(String room, Uint8List bytes) => said.add((room: room, bytes: bytes));
  @override
  void look(String room, String token) {}
  @override
  void unlook(String room) {}
  @override
  Stream<RoomEvent> get events => const Stream.empty();
  @override
  Stream<({String room, String from, Uint8List bytes})> get packets => _packets.stream;
  @override
  Stream<({String room, List<String> members})> get looks => const Stream.empty();
}

void main() {
  late NetKeys owner, admin, member;
  late Circle circle;
  final news = CircleSpace(seed: 'a1' * 32, name: 'announcements', kind: SpaceKind.text);
  final general = CircleSpace(seed: 'b2' * 32, name: 'general', kind: SpaceKind.text, order: 1);

  setUp(() async {
    owner = NetKeys.generate();
    admin = NetKeys.generate();
    member = NetKeys.generate();
    final ownerKey = NetCrypto.hex(owner.public);
    final grants = {admin.id: NetCrypto.hex(NetCrypto.sign(owner, CircleManifest.grantMessage(ownerKey, admin.id)))};
    final gs = NetCrypto.hex(NetCrypto.sign(owner, CircleManifest.grantsMessage(ownerKey, 1, grants)));
    final m = await _sign(CircleManifest(owner: ownerKey, version: 1, name: 'Night Owls', spaces: [news, general], adminGrants: grants, grantsVersion: 1, grantsSig: gs), owner);
    circle = Circle(seed: 'c3' * 32, owner: ownerKey, manifest: m, mine: true);
    Circles.instance.signerOverride = KeysSigner(owner);
    Circles.instance.join(circle);
  });
  tearDown(() async {
    Circles.instance.signerOverride = null;
    await Circles.instance.clear();
  });

  Circle held() => Circles.instance.bySeed(circle.seed)!;

  test('the welcome, the welcome space and the system space are the manifest\'s; a system space is read-only', () async {
    final circles = Circles.instance;
    expect(held().manifest.welcomeText, '');
    expect(circles.landingOf(held()), isNull);
    expect(await circles.setWelcome(held(), text: '  Welcome, {name}! Read # announcements first.  ', space: general.seed), isTrue);
    expect(held().manifest.welcomeText, 'Welcome, {name}! Read # announcements first.');
    expect(held().manifest.welcomeSpace, general.seed);
    expect(circles.landingOf(held())?.seed, general.seed);
    expect(welcomeFor(held().manifest.welcomeText, 'Maya'), 'Welcome, Maya! Read # announcements first.');
    expect(welcomeFor('Hi {name}', ''), 'Hi friend');

    expect(await circles.setSystemSpace(held(), news.seed), isTrue);
    expect(held().manifest.systemSpace, news.seed);
    expect(readOnlyOf(held().space(news.seed)!), isTrue, reason: 'a system space becomes read-only');
    expect(readOnlyOf(held().space(general.seed)!), isFalse);

    // Opened to everyone again: no longer the system space.
    expect(await circles.setReadOnly(held(), news.seed, false), isTrue);
    expect(held().manifest.systemSpace, isNull);
    expect(await circles.setReadOnly(held(), general.seed, true), isTrue);
    expect(readOnlyOf(held().space(general.seed)!), isTrue);

    // The words, and the welcome space, can go.
    expect(await circles.setWelcome(held(), text: '', space: null), isTrue);
    expect(held().manifest.extra.containsKey('wl'), isFalse);
  });

  test('a member may not change the welcome or make a space read-only', () async {
    Circles.instance.signerOverride = KeysSigner(member);
    expect(await Circles.instance.setWelcome(held(), text: 'Hi', space: null), isFalse);
    expect(await Circles.instance.setReadOnly(held(), news.seed, true), isFalse);
    expect(await Circles.instance.setSystemSpace(held(), news.seed), isFalse);
    expect(held().manifest.extra.containsKey('wl'), isFalse);
  });

  test('in a read-only space only the owner and admins post; elsewhere everyone', () async {
    await Circles.instance.setReadOnly(held(), news.seed, true);
    final c = held();
    final room = c.channelOf(c.space(news.seed)!), open = c.channelOf(c.space(general.seed)!);
    expect(Circles.instance.isReadOnly(room), isTrue);
    expect(Circles.instance.mayPostIn(room, owner.id), isTrue);
    expect(Circles.instance.mayPostIn(room, admin.id), isTrue);
    expect(Circles.instance.mayPostIn(room, member.id), isFalse);
    expect(Circles.instance.mayPostIn(open, member.id), isTrue);
  });

  test('a read-only space\'s room is bound to the owner\'s key the way the relay checks, and carries the admin list', () async {
    await Circles.instance.setReadOnly(held(), news.seed, true);
    final c = held();
    final ro = Circles.instance.readOnlyRoomFor(c.channelOf(c.space(news.seed)!))!;
    // The relay's Hub.anchoredName: SHA-256 of "ghost-ro|", the base and the owner's key, its first 16 bytes.
    final base = NetCrypto.derive(NetCrypto.unhex(news.seed), 'read-only room').sublist(0, 16);
    expect(ro.base, NetCrypto.hex(base));
    expect(ro.room, NetCrypto.hex(NetCrypto.sha256([...utf8.encode('ghost-ro|'), ...base, ...owner.public]).sublist(0, 16)));
    expect(ro.room, isNot(c.channelOf(c.space(news.seed)!).chatRoom));
    expect(ro.owner, NetCrypto.hex(owner.public));
    expect(ro.join['gv'], 1);
    expect((ro.join['g'] as Map).keys, [admin.id]);
    expect(Circles.instance.readOnlyRoomFor(c.channelOf(c.space(general.seed)!)), isNull);
  });

  test('a member\'s app: the read-only room joined with its binding, others\' words dropped, the box not offered', () async {
    await Circles.instance.setReadOnly(held(), news.seed, true);
    Circles.instance.signerOverride = KeysSigner(member);
    final c = held();
    final channel = c.channelOf(c.space(news.seed)!);
    final route = _Route(member.id);
    final store = MemoryHangoutStore()..keepRoster(channel.chatRoom, Roster.first(channel.owner));
    final room = HangoutRoom(channel: channel, route: route, name: 'Sam', signer: KeysSigner(member), store: store)
      ..mayPost = (id) => Circles.instance.mayPostIn(channel, id);
    final ro = Circles.instance.readOnlyRoomFor(channel)!;
    await room.setReadOnly(ro);
    await room.open();
    expect(route.joins.single.room, ro.room);
    expect(route.joins.single.ro?['owner'], NetCrypto.hex(owner.public));
    expect(room.mayWrite, isFalse);
    expect(room.send('hello'), isFalse);

    Map<String, Object?> msg(String id, String words) => {'t': 'msg', 'id': id, 'x': words, 'at': DateTime.now().millisecondsSinceEpoch, 'n': 'x'};
    route.hand(ro.room, member.id, channel.key, msg('m1', 'from a changed app'));
    route.hand(ro.room, NetKeys.generate().id, channel.key, msg('m2', 'from another member'));
    route.hand(ro.room, admin.id, channel.key, msg('m3', 'Meeting moved to Friday'));
    // History passed on by anyone holds only what the owner and admins wrote.
    route.hand(ro.room, member.id, channel.key, {
      't': 'hist',
      'to': member.id,
      'm': [
        {...msg('m4', 'forged history'), 'f': member.id},
        {...msg('m5', 'Rules are pinned'), 'f': owner.id},
      ],
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(room.messages.map((m) => m.text), ['Meeting moved to Friday', 'Rules are pinned']);

    // Opened to everyone again: out of the bound room and back into the space's own; what was said stays.
    await room.setReadOnly(null);
    expect(route.left, [ro.room]);
    expect(route.joins.last.room, channel.chatRoom);
    expect(route.joins.last.ro, isNull);
    expect(room.messages.length, 2);
    room.mayPost = null;
    expect(room.mayWrite, isTrue);
    await room.close();
  });

  test('a newer admin list is told to the relay without leaving the room', () async {
    await Circles.instance.setReadOnly(held(), news.seed, true);
    final c = held();
    final channel = c.channelOf(c.space(news.seed)!);
    final route = _Route(owner.id);
    final room = HangoutRoom(channel: channel, route: route, name: 'Owner', signer: KeysSigner(owner), store: MemoryHangoutStore());
    await room.setReadOnly(Circles.instance.readOnlyRoomFor(channel));
    await room.open();
    await Circles.instance.grantAdmin(held(), member.id);
    final after = held();
    await room.setReadOnly(Circles.instance.readOnlyRoomFor(after.channelOf(after.space(news.seed)!)));
    expect(route.left, isEmpty);
    expect(route.anchors.single.grants['gv'], 2);
    expect((route.anchors.single.grants['g'] as Map).keys, containsAll([admin.id, member.id]));
    expect(Circles.instance.mayPostIn(channel, member.id), isTrue);
    await room.close();
  });

  test('the system space\'s notes: joins heard, removals and admins made or taken away', () async {
    final circles = Circles.instance;
    circles.noteSeen(held(), {member.id: 'Sam Rivera', admin.id: 'Maya Chen'});
    final now = DateTime.now().millisecondsSinceEpoch;
    circles.heardJoined(held(), member.id, 'Sam Rivera', now);
    circles.heardJoined(held(), member.id, 'Sam Rivera', now + 5);
    expect(circles.systemNotesIn(held()).map((n) => n.line), ['Sam Rivera joined the circle'], reason: 'each join once');
    await circles.grantAdmin(held(), member.id);
    await circles.grantAdmin(held(), admin.id, on: false);
    await circles.kickMember(held(), admin.id);
    await circles.removeMember(held(), member.id);
    expect(circles.systemNotesIn(held()).map((n) => n.line), [
      'Sam Rivera joined the circle',
      'Sam Rivera is now an admin',
      'Maya Chen is no longer an admin',
      'Maya Chen was kicked from the circle',
      // An admin put out stops being one first (Circles.removeMember: two signed changes), and both are told.
      'Sam Rivera is no longer an admin',
      'Sam Rivera was banned from the circle',
    ]);
    final round = CircleSystemNote.fromJson(jsonDecode(jsonEncode(circles.systemNotesIn(held()).last.toJson())));
    expect(round, circles.systemNotesIn(held()).last);
  });
}
