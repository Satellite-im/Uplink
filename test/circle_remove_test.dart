import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/voice.dart';

/// Removing someone from a circle (Matt, 2026-11-19: "add the ability to remove members from a circle as an admin"):
/// the owner or an admin says so in the circle's signed manifest; the person's own app leaves it, and every member's
/// app leaves them out of its spaces.
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
    final first = !r.any((o) => o.me == me);
    final others = {for (final o in r) if (o.me != me) o.me}.toList();
    if (!r.contains(this)) r.add(this);
    if (first) {
      for (final o in r) {
        if (o.me != me) scheduleMicrotask(() => o._events.add(RoomEvent(room, came: me)));
      }
    }
    return others;
  }

  @override
  void leave(String room) {
    final r = hub.rooms[room];
    if (r == null || !r.remove(this)) return;
    if (r.any((o) => o.me == me)) return;
    for (final o in r) {
      scheduleMicrotask(() => o._events.add(RoomEvent(room, went: me)));
    }
  }

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


Future<void> _until(bool Function() ok) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!ok() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Circle _copy(Circle c) => Circle.fromJson(jsonDecode(jsonEncode(c.toJson())))!;

void main() {
  test('the owner removes a member: their app leaves the circle, and an admin may remove neither the owner nor an admin', () async {
    final hub = _Hub();
    final owner = NetKeys.generate(), admin = NetKeys.generate(), sam = NetKeys.generate();
    final mine = Circles.forTest(signer: KeysSigner(owner), route: _Route(hub, owner.id));
    final c = (await mine.make(name: 'Book club'))!;
    expect(await mine.grantAdmin(c, admin.id), isTrue);
    final theirs = Circles.forTest(signer: KeysSigner(admin), route: _Route(hub, admin.id));
    theirs.join(_copy(mine.bySeed(c.seed)!));
    final samDevice = Circles.forTest(signer: KeysSigner(sam), route: _Route(hub, sam.id));
    samDevice.join(_copy(mine.bySeed(c.seed)!));
    await _until(() => theirs.bySeed(c.seed)!.manifest.canSign(admin.id) && samDevice.bySeed(c.seed)!.manifest.isSigned);

    final m = theirs.bySeed(c.seed)!.manifest;
    expect(m.mayRemove(admin.id, owner.id), isFalse);
    expect(m.mayRemove(sam.id, admin.id), isFalse, reason: 'a member may remove nobody');
    expect(m.mayRemove(owner.id, admin.id), isTrue);
    expect(m.mayRemove(admin.id, sam.id), isTrue);

    expect(await theirs.removeMember(theirs.bySeed(c.seed)!, sam.id), isTrue);
    await _until(() => samDevice.bySeed(c.seed) == null);
    expect(samDevice.bySeed(c.seed), isNull, reason: 'Sam\'s app left the circle');
    expect(samDevice.removedFrom.value, 'Book club');
    await _until(() => mine.bySeed(c.seed)!.manifest.removed.contains(sam.id));
    expect(mine.bySeed(c.seed)!.manifest.permsOf(sam.id), isEmpty);

    // The owner removes the admin: no longer one, and out.
    expect(await mine.removeMember(mine.bySeed(c.seed)!, admin.id), isTrue);
    final after = mine.bySeed(c.seed)!.manifest;
    expect(after.granted(admin.id), isFalse);
    expect(after.removed, {sam.id, admin.id});
    // And lets Sam back.
    expect(await mine.removeMember(mine.bySeed(c.seed)!, sam.id, back: true), isTrue);
    expect(mine.bySeed(c.seed)!.manifest.removed, {admin.id});
  });

  // Matt, 2026-11-20: "I can't seem to kick users or ban them from circles, please add that functionality".
  test('a kick puts someone out now, and they may come back; a ban keeps them out until unbanned', () async {
    final hub = _Hub();
    final owner = NetKeys.generate(), sam = NetKeys.generate();
    final mine = Circles.forTest(signer: KeysSigner(owner), route: _Route(hub, owner.id));
    final c = (await mine.make(name: 'Book club'))!;
    final samDevice = Circles.forTest(signer: KeysSigner(sam), route: _Route(hub, sam.id));
    samDevice.join(_copy(mine.bySeed(c.seed)!));
    await _until(() => samDevice.bySeed(c.seed)?.manifest.isSigned ?? false);

    // Kicked: Sam's app leaves and says so; he is not banned.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(await mine.kickMember(mine.bySeed(c.seed)!, sam.id), isTrue);
    await _until(() => samDevice.bySeed(c.seed) == null);
    expect(samDevice.bySeed(c.seed), isNull);
    expect(samDevice.removedFrom.value, 'Book club');
    expect(mine.bySeed(c.seed)!.manifest.removed, isEmpty, reason: 'a kick is not a ban');
    expect(mine.bySeed(c.seed)!.manifest.kicked.keys, [sam.id]);

    // Back by the link: the kick was before he came in again, so he stays.
    samDevice.removedFrom.value = null;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    samDevice.join(Circle.fromLink(mine.bySeed(c.seed)!.link)!);
    await _until(() => samDevice.bySeed(c.seed)?.manifest.kicked.containsKey(sam.id) ?? false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(samDevice.bySeed(c.seed), isNotNull, reason: 'kicked before he came back: he stays');
    expect(samDevice.removedFrom.value, isNull);

    // Banned: out, and kept out.
    expect(await mine.removeMember(mine.bySeed(c.seed)!, sam.id), isTrue);
    await _until(() => samDevice.bySeed(c.seed) == null);
    expect(samDevice.bySeed(c.seed), isNull);
    samDevice.join(Circle.fromLink(mine.bySeed(c.seed)!.link)!);
    await _until(() => samDevice.bySeed(c.seed) == null);
    expect(samDevice.bySeed(c.seed), isNull, reason: 'banned: his app leaves again as soon as it hears the circle');

    // Unbanned: he may come back.
    expect(await mine.removeMember(mine.bySeed(c.seed)!, sam.id, back: true), isTrue);
    samDevice.join(Circle.fromLink(mine.bySeed(c.seed)!.link)!);
    await _until(() => samDevice.bySeed(c.seed)?.manifest.removed.isEmpty == true && (samDevice.bySeed(c.seed)?.manifest.isSigned ?? false));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(samDevice.bySeed(c.seed), isNotNull);
  });

  test('in a circle\'s space, whoever was removed is not heard', () async {
    final hub = _Hub();
    final c = VoiceChannel.make('General', kind: SpaceKind.text);
    final room = HangoutRoom(channel: c, route: _Route(hub, 'me'), name: 'Me')..shut = (id) => id == 'gone';
    await room.open();
    for (final who in ['gone', 'maya']) {
      final r = _Route(hub, who);
      await r.join(c.chatRoom, c.chatToken);
      r.send(c.chatRoom, NetCrypto.seal(c.key, utf8.encode(jsonEncode({'t': 'msg', 'id': 'm-$who', 'x': 'hello from $who', 'at': 1, 'n': who}))));
    }
    await _until(() => room.messages.length == 1);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect([for (final m in room.messages) m.from], ['maya']);
    await room.close();
  });

  test('a friend\'s shared number and linked accounts are kept with them', () {
    final b = Buddy(username: 'maya', id: 'm1', key: 'k', links: const {'phone': '+15550100', 'telegram': '@mayac'});
    expect(Buddy.fromJson(b.toJson())!.links, {'phone': '+15550100', 'telegram': '@mayac'});
    expect(Buddy.fromJson({'u': 'maya', 'i': 'm1', 'k': 'k', 'l': 'nonsense'})!.links, isEmpty);
  });
}
