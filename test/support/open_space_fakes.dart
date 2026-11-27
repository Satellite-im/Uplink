import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/voice/open_space.dart';
import 'package:ghost_messaging/voice/voice.dart';

/// Stand-ins an open space's tests share (test/open_space_test.dart, open_space_view_test.dart): the relay's rooms, a
/// call's media that remembers each person's gain, and somewhere to keep a space's groups.

class FakeHub {
  final Map<String, List<FakeRoute>> rooms = {};
}

class FakeRoute implements VoiceRoute {
  FakeRoute(this.hub, this.me);
  final FakeHub hub;
  @override
  final String me;
  final _events = StreamController<RoomEvent>.broadcast();
  final _packets = StreamController<({String room, String from, Uint8List bytes})>.broadcast();
  final _looks = StreamController<({String room, List<String> members})>.broadcast();

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

/// WebRTC stood in for: it remembers the gain each person was last set to.
class FakeMedia implements VoiceMedia, PlacedMedia {
  @override
  final ValueNotifier<Map<String, double>> levels = ValueNotifier(const {});
  final Map<String, double> gains = {};
  @override
  void setPlaceGain(String id, double gain) => gains[id] = gain;
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
  VoicePeer peer(String id, {required void Function(Map<String, dynamic> candidate) onCandidate}) => FakePeer();
  @override
  void setPeerVolume(String id, double volume) {}
  @override
  void setPeerMuted(String id, bool muted) {}
}

class FakePeer implements VoicePeer {
  static const _opus = 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\n';
  @override
  Future<String> makeOffer() async => _opus;
  @override
  Future<String> takeOffer(String sdp) async => _opus;
  @override
  Future<void> takeAnswer(String sdp) async {}
  @override
  Future<void> addCandidate(Map<String, dynamic> candidate) async {}
  @override
  Future<void> close() async {}
}

class FakeStore implements OpenStore {
  final Map<String, String> kept = {};
  @override
  String? read(String key) => kept[key];
  @override
  void write(String key, String value) => kept[key] = value;
}

