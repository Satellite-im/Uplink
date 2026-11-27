// A deletion said live that comes before the kept message it deletes: a relay hands a room's kept messages over a
// piece at a time, and on relays from before the third review (2026-11-23) something said live meanwhile could come
// first. Turned into a test from that review's probe.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/voice.dart';

class _Hub {
  final Map<String, Map<String, _Route>> rooms = {};
}

class _Route implements VoiceRoute {
  _Route(this.hub, this.me);
  final _Hub hub;
  @override
  final String me;
  final inEvents = StreamController<RoomEvent>.broadcast();
  final inPackets = StreamController<({String room, String from, Uint8List bytes})>.broadcast();
  final _looks = StreamController<({String room, List<String> members})>.broadcast();

  /// Everything this install said, in order.
  final said = <({String room, Uint8List bytes})>[];

  @override
  Future<List<String>> join(String room, String token) async {
    final r = hub.rooms[room] ??= {};
    final others = r.keys.toList();
    r[me] = this;
    for (final o in r.values) {
      if (o != this) scheduleMicrotask(() => o.inEvents.add(RoomEvent(room, came: me)));
    }
    return others;
  }

  @override
  void leave(String room) {
    hub.rooms[room]?.remove(me);
  }

  @override
  void send(String room, Uint8List bytes) {
    said.add((room: room, bytes: bytes));
    for (final o in hub.rooms[room]?.values ?? const <_Route>[]) {
      if (o != this) scheduleMicrotask(() => o.inPackets.add((room: room, from: me, bytes: bytes)));
    }
  }

  @override
  void look(String room, String token) {}
  @override
  void unlook(String room) {}
  @override
  Stream<RoomEvent> get events => inEvents.stream;
  @override
  Stream<({String room, String from, Uint8List bytes})> get packets => inPackets.stream;
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
  test('a deletion said live that comes before the kept message it deletes: the message stays deleted when it comes', () async {
    final hub = _Hub();
    final owner = _Install(hub, 'Matt'), ann = _Install(hub, 'Ann'), bob = _Install(hub, 'Bob');
    final channel = VoiceChannel.make('Friday hang', owner: owner.key);
    final o = owner.room(channel), a = ann.room(channel);
    await o.open();
    await a.open();
    await _settle();
    // Ann writes while Bob's phone is closed: kept by the relay.
    final before = ann.route.said.length;
    a.send('a message she then takes back');
    await _settle();
    final written = ann.route.said.sublist(before);
    final m = a.messages.firstWhere((x) => x.text == 'a message she then takes back');
    // Bob opens the app: the relay starts handing over what the room kept. Meanwhile Ann deletes it, live.
    final b = bob.room(channel);
    await b.open();
    await _settle();
    final at = ann.route.said.length;
    a.delete(m);
    await _settle();
    final deletion = ann.route.said.sublist(at);
    // The live deletion reaches Bob before the kept message it is about (as a relay from before this round could do).
    for (final p in deletion) {
      bob.route.inPackets.add((room: p.room, from: ann.id, bytes: p.bytes));
    }
    await _settle();
    for (final p in written) {
      bob.route.inPackets.add((room: p.room, from: ann.id, bytes: p.bytes));
    }
    await _settle();
    expect(b.messages.any((x) => x.id == m.id), isFalse, reason: 'a deletion that came before its message was passed over, and the message is shown');
  });
}
