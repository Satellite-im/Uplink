import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/voice/spotify_app.dart';
import 'package:ghost_messaging/voice/spotify_deck.dart';
import 'package:ghost_messaging/voice/spotify_link.dart';
import 'package:ghost_messaging/voice/spotify_lossless.dart';
import 'package:ghost_messaging/voice/voice.dart';

/// A hub, media, Spotify and music connections stood in for, for the tests of Spotify in a call.
class FakeHub {
  final Map<String, Map<String, FakeRoute>> rooms = {};

  /// Everything said in any room, as it went.
  int packets = 0;
}

class FakeRoute implements VoiceRoute {
  FakeRoute(this.hub, this.me);
  final FakeHub hub;
  @override
  final String me;
  final _events = StreamController<RoomEvent>.broadcast();
  final _packets = StreamController<({String room, String from, Uint8List bytes})>.broadcast();

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
    for (final o in r?.values ?? const <FakeRoute>[]) {
      scheduleMicrotask(() => o._events.add(RoomEvent(room, went: me)));
    }
  }

  @override
  void send(String room, Uint8List bytes) {
    hub.packets++;
    for (final o in hub.rooms[room]?.values ?? const <FakeRoute>[]) {
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
  Stream<({String room, List<String> members})> get looks => const Stream.empty();
}

class FakeMedia implements VoiceMedia {
  @override
  final ValueNotifier<Map<String, double>> levels = ValueNotifier(const {});
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  bool mutedNow = false;
  @override
  set muted(bool on) => mutedNow = on;
  @override
  set deafened(bool on) {}
  @override
  Future<void> setVideo(bool on) async {}
  @override
  VoicePeer peer(String id, {required void Function(Map<String, dynamic> candidate) onCandidate}) => _Peer();
  @override
  void setPeerVolume(String id, double volume) {}
  @override
  void setPeerMuted(String id, bool muted) {}
}

class _Peer implements VoicePeer {
  static const _sdp = 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\n';
  @override
  Future<String> makeOffer() async => _sdp;
  @override
  Future<String> takeOffer(String sdp) async => _sdp;
  @override
  Future<void> takeAnswer(String sdp) async {}
  @override
  Future<void> addCandidate(Map<String, dynamic> candidate) async {}
  @override
  Future<void> close() async {}
}

Future<void> settle() async {
  for (var i = 0; i < 14; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// A Spotify that does as it is told, and says what it was told.
class FakeSpotify implements SpotifyApp {
  FakeSpotify({this.mac = true});
  @override
  final bool mac;
  @override
  bool get opens => !mac;
  bool system = true, installed = true, running = true;

  /// What every press and look is refused with; null: none is.
  String? refuse;
  SpotifyNow doing = const SpotifyNow();
  final List<String> log = [];

  @override
  Future<SpotifyAble> able() async => (system: system, installed: installed, running: running);

  void _may() {
    if (!running) throw const SpotifyRefused('closed');
    if (refuse != null) throw SpotifyRefused(refuse!);
  }

  @override
  Future<SpotifyNow> now() async {
    _may();
    return doing;
  }

  @override
  Future<void> play(String id) async {
    _may();
    log.add('play $id');
    doing = SpotifyNow(state: 'playing', uri: 'spotify:track:$id', title: 'Title of $id', artist: 'Someone', length: const Duration(seconds: 200));
  }

  /// The song playing has got to [seconds].
  void to(int seconds, {String state = 'playing'}) =>
      doing = SpotifyNow(state: state, uri: doing.uri, title: doing.title, artist: doing.artist, length: doing.length, position: Duration(seconds: seconds));

  @override
  Future<void> pause() async {
    _may();
    log.add('pause');
    to(doing.position.inSeconds, state: 'paused');
  }

  @override
  Future<void> resume() async {
    _may();
    log.add('resume');
    to(doing.position.inSeconds);
  }

  @override
  Future<void> seek(Duration to) async {}
  @override
  void Function()? onQuit;
}

/// A music source that makes no sound: what it was asked, and the ways to say things back.
class FakeSource implements MusicSource {
  final List<String> log = [];
  String? refuse;
  double loud = 0.3;
  bool begun = false;
  final Set<String> links = {};

  @override
  Future<void> begin() async {
    if (refuse != null) throw SpotifyRefused(refuse!);
    begun = true;
    log.add('begin');
  }

  @override
  Future<void> end() async {
    begun = false;
    links.clear();
    log.add('end');
  }

  @override
  Future<double> level() async => loud;

  @override
  Future<String?> offer(String id, {required List<Map<String, Object>> servers, required bool relayOnly, required bool lossless}) async {
    log.add('offer $id${relayOnly ? ' by the relay' : ''}${lossless ? ' with a channel' : ''}');
    links.add(id);
    ways.remove(id);
    if (lossless) ways[id] = (open: false, bytes: 0, dropped: 0, relay: null);
    return 'offer for $id${lossless ? ' m=application' : ''}';
  }

  /// Who has the music without loss, and how it goes for them.
  final Map<String, LosslessState> ways = {};
  double hz = 48000;

  @override
  Future<void> lossless(String id, {required bool on}) async {
    log.add('lossless $id ${on ? 'on' : 'off'}');
    on ? ways[id] = (open: false, bytes: 0, dropped: 0, relay: null) : ways.remove(id);
  }

  @override
  Future<Map<String, LosslessState>> losslessState() async => {...ways};

  @override
  Future<double> rate() async => hz;

  @override
  Future<bool> answer(String id, String sdp) async {
    log.add('answer $id: $sdp');
    return links.contains(id);
  }

  @override
  Future<void> candidate(String id, Map<String, dynamic> c) async => log.add('ice $id: ${c['candidate']}');
  @override
  Future<void> close(String id) async {
    links.remove(id);
    ways.remove(id);
    log.add('close $id');
  }

  @override
  void Function(String id, Map<String, dynamic> candidate)? onCandidate;
  @override
  void Function(String id, String state)? onState;
}

/// A listener's connection: what it was given, and how loud it is.
class FakeEar implements MusicEar {
  FakeEar(this.servers, this.relayOnly, this.onCandidate, this.onState, this.onLossless);
  final List<Map<String, Object>> servers;
  final bool relayOnly;
  final void Function(Map<String, dynamic>) onCandidate;
  final void Function(bool up) onState;
  final void Function(bool heard, LosslessWhy? why) onLossless;
  final List<String> log = [];
  bool take = false, plays = false;
  String speaker = '?';
  double volume = -1;
  bool silent = false, closed = false;

  @override
  Future<String> takeOffer(String sdp) async {
    log.add(sdp);
    return 'answer to $sdp';
  }

  @override
  Future<void> candidate(Map<String, dynamic> c) async => log.add('ice ${c['candidate']}');
  double loud = 0;
  int levelsAsked = 0;
  @override
  Future<double> level() async {
    levelsAsked++;
    return loud;
  }

  @override
  void set({required double volume, required bool silent}) {
    this.volume = volume;
    this.silent = silent;
  }

  @override
  Future<void> output(String deviceId) async => speaker = deviceId;
  @override
  void lossless(bool take) => this.take = take;
  @override
  void playing(bool on) => plays = on;
  @override
  Future<void> close() async => closed = true;
}
