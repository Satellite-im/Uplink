import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStream;
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/voice/screen_sound.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/spotify_stand_ins.dart';

/// The computer's sound with a shared screen (lib/voice/screen_sound.dart; GMFB-63: "Screen shares should include
/// audio controls but there are none and users can't hear any audio from the share"): who says they share it, who asks
/// for it, and who is sent it. A hub, the capture and the connections stood in for.

/// A share's sound that makes no sound: what it was asked, and what it was told.
class FakeShareSound implements ShareSoundSource {
  final List<String> log = [];
  final Set<String> links = {};
  bool ended = false;

  /// Whether a connection can't be made.
  bool refuses = false;

  @override
  void Function(String id, Map<String, dynamic> candidate)? onCandidate;
  @override
  void Function(String id, String state)? onState;

  @override
  Future<String?> offer(String id, {required List<Map<String, Object>> servers, required bool relayOnly}) async {
    log.add('offer $id${relayOnly ? ' (relay)' : ''}');
    if (refuses || ended) return null;
    links.add(id);
    return 'offer for $id';
  }

  @override
  Future<bool> answer(String id, String sdp) async {
    log.add('answer $id: $sdp');
    return links.contains(id);
  }

  @override
  Future<void> candidate(String id, Map<String, dynamic> c) async => log.add('ice $id ${c['candidate']}');

  @override
  Future<void> close(String id) async {
    if (links.remove(id)) log.add('close $id');
  }

  @override
  Future<void> end() async {
    ended = true;
    links.clear();
  }
}

/// Media that shares a screen, with its sound where it is asked for and [canSound].
class Screens extends FakeMedia implements ScreenMedia, ScreenSoundMedia {
  bool canSound = true;
  String? sharing;
  void Function()? ended;
  final List<FakeShareSound> sounds = [];

  @override
  bool get screenSupported => true;
  @override
  Future<List<ScreenSource>> screenSources() async => const [ScreenSource(id: 'screen:0', name: 'Entire screen', window: false)];
  @override
  final ValueNotifier<MediaStream?> localScreen = ValueNotifier(null);

  @override
  Future<bool> screenSoundSupported() async => canSound;
  @override
  bool screenWithSound = false;
  @override
  ShareSoundSource? screenSound;

  @override
  Future<bool> setScreen(bool on, {String? source, void Function()? onEnded}) async {
    await screenSound?.end();
    screenSound = null;
    sharing = on ? (source ?? 'phone') : null;
    ended = onEnded;
    if (on && screenWithSound && canSound) sounds.add(screenSound = FakeShareSound());
    return true;
  }

  /// The system stopped it (its own Stop sharing, the window closed).
  Future<void> systemStop() async {
    await screenSound?.end();
    screenSound = null;
    sharing = null;
    ended?.call();
  }
}

/// One device in the call.
class Device {
  Device(this.hub, VoiceChannel channel, this.id) : session = VoiceSession(channel: channel, route: FakeRoute(hub, id), media: Screens(), name: id);
  final FakeHub hub;
  final String id;
  final VoiceSession session;
  Screens get media => session.media as Screens;
  final Map<String, List<FakeEar>> ears = {};
  DateTime now = DateTime(2026, 11, 26, 20);
  bool relay = false;
  final app = AppState();

  /// Everything said of a share's sound in this device's hearing.
  final List<({String from, Map<String, dynamic> m})> said = [];

  late final sound = ScreenSound.forTest(
    source: () => media.screenSound,
    makeEar: ({required who, required servers, required relayOnly, required onCandidate, required onState}) {
      final e = FakeEar(servers, relayOnly, onCandidate, onState, (_, _) {});
      (ears[who] ??= []).add(e);
      return e;
    },
    clock: () => now,
    ways: () => (servers: const [{'urls': 'stun:x'}], relay: relay),
    store: app,
  );

  /// The newest connection to [who]'s sound here.
  FakeEar earOf(String who) => ears[who]!.last;
  FakeShareSound get source => media.sounds.last;

  Future<void> join() async {
    await session.join();
    sound.followSession(session);
    final heard = session.onShareSound!;
    session.onShareSound = (from, m) {
      said.add((from: from, m: m));
      heard(from, m);
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null));

  /// Maya and Sam in a call, with Ada where [third].
  Future<(Device, Device, Device?)> call({bool third = false}) async {
    final hub = FakeHub();
    final c = VoiceChannel.make('Friday games');
    final maya = Device(hub, c, 'maya'), sam = Device(hub, c, 'sam');
    await maya.join();
    await sam.join();
    Device? ada;
    if (third) {
      ada = Device(hub, c, 'ada');
      await ada.join();
    }
    await settle();
    addTearDown(() async {
      for (final d in [maya, sam, ?ada]) {
        d.sound.followSession(null);
        await d.session.leave();
      }
    });
    return (maya, sam, ada);
  }

  test('a screen shared with its sound: said in the call, asked for by whoever views, offered, answered and heard', () async {
    final (maya, sam, _) = await call();
    expect(await maya.session.setScreen(true, source: 'screen:0', sound: true), isTrue);
    await settle();
    expect([maya.session.screen, maya.session.screenSound, maya.media.screenWithSound], [true, true, true]);
    expect([sam.session.members['maya']!.screen, sam.session.sharingSound, sam.sound.sounds('maya')], [true, {'maya'}, true]);
    // Sam's device asked, Maya's made a connection for it alone, and each took the other's half.
    expect(maya.source.log, ['offer sam', 'answer sam: answer to offer for sam']);
    expect(sam.earOf('maya').log, ['offer for sam']);
    expect(maya.said.map((x) => x.m['k']), ['ask', 'ans']);
    expect(sam.said.map((x) => x.m['k']), ['offer']);
    expect(sam.sound.hearing('maya'), isFalse, reason: 'not until it is through');
    sam.earOf('maya').onState(true);
    expect([sam.sound.hearing('maya'), maya.sound.sendingTo], [true, 1]);
    // Ways to connect pass each way, under that connection's mark and to nobody else's.
    maya.source.onCandidate!('sam', {'candidate': 'from-maya', 'sdpMid': '0', 'sdpMLineIndex': 0});
    sam.earOf('maya').onCandidate({'candidate': 'from-sam', 'sdpMid': '0', 'sdpMLineIndex': 0});
    await settle();
    expect(sam.earOf('maya').log.last, 'ice from-maya');
    expect(maya.source.log.last, 'ice sam from-sam');
    final mark = sam.said.first.m['l'];
    sam.session.sayShareSound({'k': 'ice', 'to': 'maya', 'l': 'another', 'c': {'candidate': 'not-this-one'}});
    await settle();
    expect(maya.source.log.last, 'ice sam from-sam', reason: 'a mark that is not the connection\'s ($mark) is nothing to it');
    // It is as loud as this device says, and nothing of it is the call's own sound.
    expect([sam.earOf('maya').volume, sam.earOf('maya').silent], [1.0, false]);
    // She stops sharing: her connections end, and his is let go.
    await maya.session.setScreen(false);
    await settle();
    expect([maya.source.ended, maya.sound.sendingTo, sam.earOf('maya').closed, sam.sound.sounds('maya'), sam.sound.hearing('maya')], [true, 0, true, false, false]);
    expect(sam.session.sharingSound, isEmpty);
  });

  test('shared without its sound, or from a device that can\'t take it: nothing is said, asked or made', () async {
    final (maya, sam, _) = await call();
    await maya.session.setScreen(true, source: 'screen:0');
    await settle();
    expect([maya.session.screenSound, maya.media.sounds, sam.sound.sounds('maya'), sam.ears, maya.said, sam.said], [false, isEmpty, false, isEmpty, isEmpty, isEmpty]);
    await maya.session.setScreen(false);
    // Asked for where the device gives none (a Mac that refused, a PC with no sound to give): shared, without it.
    maya.media.canSound = false;
    expect(await maya.session.setScreen(true, source: 'screen:0', sound: true), isTrue);
    await settle();
    expect([maya.session.screen, maya.session.screenSound, sam.sound.sounds('maya'), sam.ears], [true, false, false, isEmpty]);
  });

  test('its loudness is this device\'s own: at nothing it is let go and not asked for; deafened it is silent', () async {
    final (maya, sam, _) = await call();
    await maya.session.setScreen(true, source: 'screen:0', sound: true);
    await settle();
    final first = sam.earOf('maya')..onState(true);
    expect(sam.sound.volume, 100);
    sam.sound.setVolume(40);
    expect([first.volume, sam.app.choice(ScreenSound.volumeKey, ''), maya.sound.volume], [0.4, '40', 100], reason: 'kept here, and nobody else\'s');
    sam.session.setDeafened(true);
    expect(first.silent, isTrue);
    sam.session.setDeafened(false);
    expect(first.silent, isFalse);
    // All the way down: the connection is let go, and none is asked for.
    sam.sound.setVolume(0);
    await settle();
    expect([first.closed, sam.sound.hearing('maya'), sam.ears['maya'], sam.sound.sounds('maya')], [true, false, hasLength(1), true]);
    // Up again: asked for again (her device answers one asking in two seconds).
    maya.now = maya.now.add(const Duration(seconds: 3));
    sam.sound.setVolume(70);
    await settle();
    expect([sam.ears['maya'], sam.earOf('maya').closed, sam.earOf('maya').volume], [hasLength(2), false, 0.7]);
  });

  test('a connection that drops is asked for again: through the relay first where there is one, then every path', () async {
    final (maya, sam, _) = await call();
    maya.relay = true;
    await maya.session.setScreen(true, source: 'screen:0', sound: true);
    await settle();
    final first = sam.earOf('maya')..onState(true);
    expect([first.relayOnly, maya.source.log.first], [true, 'offer sam (relay)'], reason: 'as a call\'s own connections are');
    maya.now = maya.now.add(const Duration(seconds: 5));
    first.onState(false);
    await settle();
    expect([first.closed, sam.ears['maya'], sam.earOf('maya').relayOnly, sam.sound.hearing('maya')], [true, hasLength(2), true, false], reason: 'one that was through and dropped starts over: the relay first');
    // A word from the old one is nothing to the new.
    first.onState(true);
    expect(sam.sound.hearing('maya'), isFalse);
    // The new one never comes through. The next time it asks (it waits longer each time) is its second try: every path.
    maya.now = maya.now.add(const Duration(seconds: 5));
    sam.earOf('maya').onState(false);
    await settle();
    expect(sam.ears['maya']!.last.closed, isTrue);
    sam.session.sayShareSound({'k': 'ask', 'to': 'maya', 'n': 1});
    await settle();
    expect([sam.ears['maya'], sam.earOf('maya').relayOnly], [hasLength(3), false]);
    sam.earOf('maya').onState(true);
    expect(sam.sound.hearing('maya'), isTrue);
    // Her side failing closes it there; his asks when it notices.
    maya.source.onState!('sam', 'failed');
    await settle();
    expect([maya.source.links, maya.sound.sendingTo], [isEmpty, 0]);
  });

  test('whoever comes in late hears it too; whoever leaves is sent no more; a share ended from outside the app ends its sound', () async {
    final (maya, sam, _) = await call();
    await maya.session.setScreen(true, source: 'screen:0', sound: true);
    await settle();
    sam.earOf('maya').onState(true);
    final ada = Device(maya.hub, maya.session.channel, 'ada');
    await ada.join();
    await settle();
    expect([ada.sound.sounds('maya'), ada.ears['maya'], maya.source.links], [true, hasLength(1), {'sam', 'ada'}]);
    // Sam leaves: his connection is closed at her end.
    sam.sound.followSession(null);
    await sam.session.leave();
    await settle();
    expect([maya.source.links, sam.earOf('maya').closed], [{'ada'}, true]);
    // The system's own Stop sharing: the sound ends with the picture, and Ada's device lets go.
    final source = maya.source;
    await maya.media.systemStop();
    await settle();
    expect([maya.session.screen, maya.session.screenSound, source.ended, ada.sound.sounds('maya'), ada.earOf('maya').closed], [false, false, true, false, true]);
    ada.sound.followSession(null);
    await ada.session.leave();
  });

  test('nothing hostile from the room makes a connection, and one viewer is answered no oftener than every two seconds', () async {
    final (maya, sam, ada) = await call(third: true);
    // Ada offers Sam a "sound" he never asked for (she shares nothing): nothing is made.
    ada!.session.sayShareSound({'k': 'offer', 'to': 'sam', 'l': 'abc', 'sdp': 'offer'});
    await settle();
    expect(sam.ears, isEmpty);
    // Maya shares with sound; Ada's device, made to misbehave, asks again and again.
    await maya.session.setScreen(true, source: 'screen:0', sound: true);
    await settle();
    final asked = maya.source.log.where((l) => l == 'offer ada').length;
    for (var i = 0; i < 20; i++) {
      ada.session.sayShareSound({'k': 'ask', 'to': 'maya', 'n': i});
    }
    await settle();
    expect(maya.source.log.where((l) => l == 'offer ada').length, asked, reason: 'one asking in two seconds');
    // An offer too long, an answer under a mark that is not the connection's, a way to connect that is no string: passed over.
    final before = maya.source.log.length;
    ada.session.sayShareSound({'k': 'ans', 'to': 'maya', 'l': 'not-the-mark', 'sdp': 'x'});
    ada.session.sayShareSound({'k': 'ice', 'to': 'maya', 'l': maya.said.lastWhere((x) => x.from == 'ada').m['l'] ?? '', 'c': {'candidate': 7}});
    ada.session.sayShareSound({'k': 'ice', 'to': 'maya', 'l': 5, 'c': 'x'});
    await settle();
    expect(maya.source.log.length, before);
    // What Sam is offered by someone who does share is taken only once, and only where it was asked for.
    final ears = sam.ears['maya']!.length;
    ada.session.sayShareSound({'k': 'offer', 'to': 'sam', 'l': 'abc', 'sdp': 'x' * (ScreenSound.sdpMost + 1)});
    await settle();
    expect([sam.ears['maya']!.length, sam.ears['ada']], [ears, isNull]);
    // Said to one person, and sealed as everything in the call is: what crosses the hub names no "ss" in the clear.
    final seen = <String>[];
    final sub = (ada.session.route as FakeRoute).packets.listen((p) => seen.add(utf8.decode(p.bytes, allowMalformed: true)));
    sam.sound.setVolume(0);
    maya.now = maya.now.add(const Duration(seconds: 3));
    sam.sound.setVolume(100);
    await settle();
    await sub.cancel();
    expect(seen, isNotEmpty);
    expect(seen.any((x) => x.contains('"ss"') || x.contains('offer for sam')), isFalse);
  });

  test('more shares than a device listens to at once: the first few are heard', () async {
    final hub = FakeHub();
    final c = VoiceChannel.make('Everyone shares');
    final sam = Device(hub, c, 'sam');
    await sam.join();
    final sharers = [for (var i = 0; i < ScreenSound.sharesMost + 2; i++) Device(hub, c, 'd$i')];
    for (final d in sharers) {
      await d.join();
    }
    await settle();
    for (final d in sharers) {
      await d.session.setScreen(true, source: 'screen:0', sound: true);
    }
    await settle();
    expect(sam.ears.length, ScreenSound.sharesMost);
    for (final d in [sam, ...sharers]) {
      d.sound.followSession(null);
      await d.session.leave();
    }
  });
}
