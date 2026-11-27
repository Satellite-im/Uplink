import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart';

/// A space's description (HangoutRoom.about, SpaceAbout in lib/voice/hangout.dart): Matt, 2026-11-17: "make the text
/// header for spaces show the icon and the name and an area for a description of the channel". It is signed apart from
/// the roster, by the owner or an admin the roster trusts, and the highest version wins.
///
/// The hub stood in for as in hangout_test.dart, each install with a real key, so abouts are really signed and checked.
class _Hub {
  final Map<String, Map<String, _Route>> rooms = {};
}

class _Route implements VoiceRoute {
  _Route(this.hub, this.me);
  final _Hub hub;
  @override
  final String me;
  final _events = StreamController<RoomEvent>.broadcast();
  final _packets = StreamController<({String room, String from, Uint8List bytes})>.broadcast();
  final _looks = StreamController<({String room, List<String> members})>.broadcast();

  /// Everything this install sent, to see a forged packet go in.
  @override
  Future<List<String>> join(String room, String token) async {
    final r = hub.rooms[room] ??= {};
    final others = r.keys.toList();
    r[me] = this;
    for (final o in r.values) {
      if (o != this) scheduleMicrotask(() => o._events.add(RoomEvent(room, came: me)));
    }
    return others;
  }

  @override
  void leave(String room) {
    final r = hub.rooms[room];
    r?.remove(me);
    for (final o in r?.values ?? const <_Route>[]) {
      scheduleMicrotask(() => o._events.add(RoomEvent(room, went: me)));
    }
  }

  @override
  void send(String room, Uint8List bytes) {
    for (final o in hub.rooms[room]?.values ?? const <_Route>[]) {
      if (o != this) scheduleMicrotask(() => o._packets.add((room: room, from: me, bytes: bytes)));
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

class _Install {
  _Install(this.hub, this.name) : keys = NetKeys.generate();
  final _Hub hub;
  final String name;
  final NetKeys keys;
  final store = MemoryHangoutStore();
  late final route = _Route(hub, keys.id);
  String get id => keys.id;
  String get key => NetCrypto.hex(keys.public);

  HangoutRoom room(VoiceChannel c) => HangoutRoom(channel: c, route: route, name: name, signer: KeysSigner(keys), store: store);
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _Hub hub;
  late _Install owner, ann, bob;
  late VoiceChannel channel;

  setUp(() {
    hub = _Hub();
    owner = _Install(hub, 'Matt');
    ann = _Install(hub, 'Ann');
    bob = _Install(hub, 'Bob');
    channel = VoiceChannel.make('Book club', owner: owner.key, kind: SpaceKind.text);
  });

  Future<SpaceAbout> signed(_Install by, String text, int version) =>
      SpaceAbout.sign(channel.chatRoom, text, version, by.id, by.keys.public, (m) async => NetCrypto.sign(by.keys, m));

  test('the owner\'s description is believed, travels to everyone in the room, and is kept', () async {
    final o = owner.room(channel), a = ann.room(channel);
    await o.open();
    await a.open();
    await _settle();
    expect(await o.setAbout('  Fiction on Fridays; bring a chapter.  '), isTrue);
    await _settle();
    expect(o.about, 'Fiction on Fridays; bring a chapter.');
    expect(a.about, 'Fiction on Fridays; bring a chapter.', reason: 'heard as `about` in the chat room');
    // Kept in the store: a room made again from it starts with it.
    final again = HangoutRoom(channel: channel, route: _Route(hub, ann.id), name: 'Ann', store: ann.store);
    expect(again.about, 'Fiction on Fridays; bring a chapter.');
    // An admin the owner made may write it too.
    final admin = await o.setRole(ann.id, Role.admin);
    expect(admin, isTrue);
    await _settle();
    expect(await a.setAbout('Now with snacks'), isTrue);
    await _settle();
    expect(o.about, 'Now with snacks');
  });

  test('a newcomer gets the description when it asks what it missed', () async {
    final o = owner.room(channel);
    await o.open();
    expect(await o.setAbout('Quiet reading'), isTrue);
    final b = bob.room(channel);
    await b.open();
    await _settle();
    expect(b.about, 'Quiet reading');
  });

  test('a member\'s description is refused, both said and asked to be made', () async {
    final o = owner.room(channel), b = bob.room(channel);
    await o.open();
    await b.open();
    await _settle();
    expect(await b.setAbout('Bob was here'), isFalse, reason: 'a member may not write it');
    // Signed by Bob and said into the room anyway: believed by no one.
    final forged = await signed(bob, 'Bob was here', 5);
    expect(forged.trustedFor(channel.chatRoom, o.roster), isFalse);
    bob.route.send(channel.chatRoom, NetCrypto.seal(channel.key, utf8.encode(jsonEncode({'t': 'about', 'a': forged.toJson()}))));
    await _settle();
    expect(o.about, isNull);
  });

  test('the highest version wins, in whatever order they come', () async {
    final o = owner.room(channel), a = ann.room(channel);
    await o.open();
    await a.open();
    await _settle();
    final v2 = await signed(owner, 'Second', 2), v1 = await signed(owner, 'First', 1), v3 = await signed(owner, 'Third', 3);
    // Passed on by Bob, who may not write one himself: whoever carries it, the owner's signature is what counts.
    for (final x in [v2, v1, v3, v1]) {
      bob.route.send(channel.chatRoom, NetCrypto.seal(channel.key, utf8.encode(jsonEncode({'t': 'about', 'a': x.toJson()}))));
      await _settle();
    }
    expect(a.about, 'Third');
    expect(o.about, 'Third');
    // The next one written is numbered after the highest seen.
    expect(await a.setAbout('nope'), isFalse);
    expect(await o.setAbout('Fourth'), isTrue);
    await _settle();
    expect(a.about, 'Fourth');
  });

  test('one changed after it was signed is refused, as is one carried to another space', () async {
    final roster = Roster.first(owner.key);
    final good = await signed(owner, 'Mysteries only', 1);
    expect(good.trustedFor(channel.chatRoom, roster), isTrue);
    expect(SpaceAbout.fromJson(good.toJson())!.trustedFor(channel.chatRoom, roster), isTrue, reason: 'it travels as JSON');
    final tampered = SpaceAbout.fromJson({...good.toJson(), 'd': 'Horror only'})!;
    expect(tampered.trustedFor(channel.chatRoom, roster), isFalse);
    final bumped = SpaceAbout.fromJson({...good.toJson(), 'v': 9})!;
    expect(bumped.trustedFor(channel.chatRoom, roster), isFalse);
    // Bob's key named as the signer of the owner's signature.
    final reKeyed = SpaceAbout.fromJson({...good.toJson(), 'by': bob.id, 'k': bob.key})!;
    expect(reKeyed.trustedFor(channel.chatRoom, roster), isFalse);
    final other = VoiceChannel.make('Other', owner: owner.key);
    expect(good.trustedFor(other.chatRoom, roster), isFalse);
    // Too long, or no version: not one at all.
    expect(SpaceAbout.fromJson({...good.toJson(), 'd': 'x' * 301}), isNull);
    expect(SpaceAbout.fromJson({...good.toJson(), 'v': 0}), isNull);

    // In the room: the tampered one is passed over.
    final o = owner.room(channel), a = ann.room(channel);
    await o.open();
    await a.open();
    await _settle();
    owner.route.send(channel.chatRoom, NetCrypto.seal(channel.key, utf8.encode(jsonEncode({'t': 'about', 'a': tampered.toJson()}))));
    await _settle();
    expect(a.about, isNull);
  });

  test('an admin\'s description that comes before the roster making them admin is taken once that roster does', () async {
    final o = owner.room(channel), b = bob.room(channel);
    await o.open();
    expect(await o.setRole(ann.id, Role.admin), isTrue);
    final byAnn = await signed(ann, 'Ann\'s words', 1);
    expect(byAnn.trustedFor(channel.chatRoom, Roster.first(owner.key)), isFalse, reason: 'not an admin by the first roster');
    expect(byAnn.trustedFor(channel.chatRoom, o.roster), isTrue);
    await b.open();
    // Bob hears Ann's about first, then the roster.
    ann.route.send(channel.chatRoom, NetCrypto.seal(channel.key, utf8.encode(jsonEncode({'t': 'about', 'a': byAnn.toJson()}))));
    await _settle();
    expect(b.roster.version, greaterThan(0));
    expect(b.about, 'Ann\'s words');
  });
}
