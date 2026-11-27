import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/hub_pair.dart';

/// Two windows of one install and a call (GMFB-47, Kevin on Windows: "Having two gm windows open on windows creates a
/// loop in a call of disconnecting and reconnecting as the two windows battle for control").
///
/// Two windows of one install are one device to the relay (the same `hub_device`, read from the same folder), and the
/// relay keeps one connection a device: the second window's takes the first's place (4409), the first dials again and
/// takes it back, and so on, every few seconds. The window in the call took each turn for the relay being lost for a
/// moment, came back into the room and offered everyone a new connection, each time. Now a window whose place was taken
/// leaves the call and stays out of it until its person joins again.

/// WebRTC stood in for: each connection says what it was asked to make and take.
class _Media implements VoiceMedia {
  @override
  final ValueNotifier<Map<String, double>> levels = ValueNotifier(const {});
  final log = <String>[];
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async => log.add('stopped');
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
    media.log.add('offer to $id');
    return _opus;
  }

  @override
  Future<String> takeOffer(String sdp) async {
    media.log.add('answer $id');
    return _opus;
  }

  @override
  Future<void> takeAnswer(String sdp) async => media.log.add('took answer from $id');
  @override
  Future<void> addCandidate(Map<String, dynamic> candidate) async {}
  @override
  Future<void> close() async => media.log.add('closed $id');
}

/// Waits until [ok] holds, or five seconds go by: never a fixed sleep, which a busy machine outruns.
Future<void> _until(bool Function() ok) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!ok() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  final device = HubCarrier.device;
  setUp(() => HubCarrier.device = 'ab' * 16);
  tearDown(() => HubCarrier.device = device);

  test('a window whose place on the relay a second window took leaves the call and stays out of it', () async {
    // A real hub (relay/lib/hub.dart) in memory, and every window's own carrier dialling it again 40 ms after it is
    // put off, as the app's does after 3 s.
    final memory = MemoryHub();
    final matt = NetKeys.generate(), maya = NetKeys.generate();
    HubCarrier window(NetKeys keys) => HubCarrier(url: memory.url, signer: KeysSigner(keys), retry: const Duration(milliseconds: 40), dial: memory.dial);
    Future<void> up(HubCarrier c) async {
      await c.start();
      await _until(() => c.state.value == CarrierState.up);
      expect(c.state.value, CarrierState.up);
    }

    final first = window(matt), second = window(matt), hers = window(maya);
    addTearDown(() async {
      await first.stop();
      await second.stop();
      await hers.stop();
    });
    await up(first);
    await up(hers);

    final c = VoiceChannel.make('Lounge');
    final firstMedia = _Media(), herMedia = _Media();
    final mine = VoiceSession(channel: c, route: HubVoiceRoute(first), media: firstMedia, name: 'Matt');
    final theirs = VoiceSession(channel: c, route: HubVoiceRoute(hers), media: herMedia, name: 'Maya');
    var movedAway = 0;
    mine.onMovedAway = () async {
      movedAway++;
      await mine.leave();
    };
    await mine.join();
    await theirs.join();
    await _until(() => firstMedia.log.contains('answer ${maya.id}') && herMedia.log.contains('took answer from ${matt.id}'));
    expect(theirs.members.keys, [matt.id]);

    // The app is started a second time: another window of the same install, the same device to the relay. It is in no
    // call. The two take each other's place on the relay, turn about; a few rounds of it go by.
    final dials = memory.pairs.length;
    await second.start();
    await _until(() => memory.pairs.length >= dials + 7 && !mine.joined);

    expect(memory.pairs.where((p) => p.code == 4409), isNotEmpty, reason: 'the relay put a window off for the other');
    expect(mine.joined, isFalse, reason: 'it came back into the call by itself each time its place was taken');
    expect(movedAway, 1, reason: 'told once, as when another device takes the call');
    expect(firstMedia.log, contains('stopped'));
    expect(firstMedia.log.where((l) => l.startsWith('offer to')), isEmpty, reason: 'it offered Maya a new connection each time it came back');
    final offered = herMedia.log.where((l) => l.startsWith('answer')).length;
    await _until(() => memory.pairs.length >= dials + 12);
    expect(mine.joined, isFalse);
    expect(mine.reconnecting, isFalse);
    expect(herMedia.log.where((l) => l.startsWith('answer')).length, offered, reason: 'nothing more is asked of Maya');
    await _until(() => theirs.members.isEmpty);
    expect(theirs.members, isEmpty, reason: 'Matt is out of the call for her too');

    // Its person joins again from the window that was put out: in, as on any join.
    await first.stop();
    await up(second);
    final again = VoiceSession(channel: c, route: HubVoiceRoute(second), media: _Media(), name: 'Matt');
    await again.join();
    await _until(() => theirs.members.containsKey(matt.id) && again.members.containsKey(maya.id));
    expect(again.joined, isTrue);
    expect(theirs.members.keys, [matt.id]);
    await again.leave();
    await theirs.leave();
  });

  test('a connection that only dropped is still mended: the call stays, and comes back with the relay', () async {
    final memory = MemoryHub();
    final matt = NetKeys.generate();
    final only = HubCarrier(url: memory.url, signer: KeysSigner(matt), retry: const Duration(milliseconds: 40), dial: memory.dial);
    addTearDown(only.stop);
    await only.start();
    await _until(() => only.state.value == CarrierState.up);
    final s = VoiceSession(channel: VoiceChannel.make('Lounge'), route: HubVoiceRoute(only), media: _Media(), name: 'Matt');
    var movedAway = 0;
    s.onMovedAway = () async {
      movedAway++;
      await s.leave();
    };
    await s.join();
    var lost = false;
    s.addListener(() => lost = lost || s.reconnecting);
    memory.pairs.last.cut();
    await _until(() => lost && !s.reconnecting && memory.pairs.length == 2);
    expect(lost, isTrue);
    expect(s.joined, isTrue, reason: 'a network going for a moment is not another window');
    expect(s.reconnecting, isFalse);
    expect(movedAway, 0);
    await s.leave();
  });
}
