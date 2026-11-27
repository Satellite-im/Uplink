import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_seen.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/voice/spotify.dart';
import 'package:ghost_messaging/voice/spotify_app.dart';
import 'package:ghost_messaging/voice/spotify_deck.dart';
import 'package:ghost_messaging/voice/spotify_queue.dart';
import 'package:ghost_messaging/voice/voice.dart';
import 'package:ghost_messaging/voice/voice_fx.dart';
import 'package:ghost_messaging/voice/voice_settings.dart';

import 'support/spotify_stand_ins.dart';

/// Spotify in a call (lib/voice/spotify.dart): who is the DJ, what is said and asked, and who is sent the music. A hub,
/// WebRTC and Spotify stood in for.
const a = '4cOdK2wGLETKBW3PvgPWqT', b = '11dFghVXANMlKmJXsNCbNl', c = '3n3Ppam7vgaVa1iaRUc9Lp';
String link(String id) => 'https://open.spotify.com/track/$id';

/// One device in the call.
class Device {
  Device(this.hub, VoiceChannel channel, this.id, {this.computer = true, this.mac = true}) : session = VoiceSession(channel: channel, route: FakeRoute(hub, id), media: FakeMedia(), name: id);
  final FakeHub hub;
  final String id;
  final bool computer, mac;
  final VoiceSession session;
  late final spotify = FakeSpotify(mac: mac);
  final source = FakeSource();
  final List<FakeEar> ears = [];
  bool on = true;
  final Set<String> mayNot = {};
  DateTime now = DateTime(2026, 11, 25, 20);
  bool relay = false;
  final app = AppState();

  /// Everything said of the music in this device's hearing.
  final List<({String from, Map<String, dynamic> m})> said = [];

  late final music = SpotifyMusic.forTest(
    isOn: () => on,
    maySpeak: (who) => !mayNot.contains(who),
    app: () => computer ? spotify : null,
    source: () => computer ? source : null,
    makeEar: ({required servers, required relayOnly, required onCandidate, required onState, required onLossless}) {
      final e = FakeEar(servers, relayOnly, onCandidate, onState, onLossless);
      ears.add(e);
      return e;
    },
    clock: () => now,
    ways: () => (servers: const [{'urls': 'stun:x'}], relay: relay),
    store: app,
  );

  Future<void> join() async {
    await session.join();
    music.followSession(session);
    final heard = session.onMusic!;
    session.onMusic = (from, m) {
      said.add((from: from, m: m));
      heard(from, m);
    };
    await settle();
  }

  Future<void> leave() async {
    music.followSession(null);
    await session.leave();
    await settle();
  }

  FakeEar get ear => ears.last;

  /// A second goes by at the DJ's.
  Future<void> look({int seconds = 1}) async {
    now = now.add(Duration(seconds: seconds));
    await music.look();
    await settle();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null));

  late FakeHub hub;
  late VoiceChannel channel;
  final devices = <Device>[];
  Device device(String id, {bool computer = true, bool mac = true}) {
    final d = Device(hub, channel, id, computer: computer, mac: mac);
    devices.add(d);
    return d;
  }

  setUp(() {
    hub = FakeHub();
    channel = VoiceChannel.make('Friday');
  });
  tearDown(() async {
    for (final d in devices) {
      await d.leave();
    }
    devices.clear();
  });

  /// A DJ (maya, a Mac) and a listener (sam, a phone), playing.
  Future<(Device, Device)> playing() async {
    final maya = device('maya'), sam = device('sam', computer: false);
    await maya.join();
    await sam.join();
    expect(await maya.music.start(), isTrue);
    await settle();
    expect(await sam.music.add(link(a)), isNull);
    await settle();
    return (maya, sam);
  }

  test('start, a song asked for by a listener, and the music sent to them', () async {
    final (maya, sam) = await playing();
    expect(sam.music.dj, 'maya');
    expect(sam.music.canDj, isFalse);
    expect(maya.spotify.log, ['play $a']);
    expect(sam.music.state!.now!.song.track, a);
    expect(sam.music.state!.now!.by, 'sam');
    expect(sam.music.state!.playing, isTrue);
    // The connection: asked for by the listener, offered by the DJ, answered.
    expect(sam.ears, hasLength(1));
    expect(sam.ear.log, ['offer for sam']);
    expect(maya.source.log, containsAllInOrder(['begin', 'offer sam', 'answer sam: answer to offer for sam']));
    maya.source.onCandidate!('sam', {'candidate': 'from the DJ', 'sdpMid': '0', 'sdpMLineIndex': 0});
    sam.ear.onCandidate({'candidate': 'from the listener', 'sdpMid': '0', 'sdpMLineIndex': 0});
    await settle();
    expect(sam.ear.log.last, 'ice from the DJ');
    expect(maya.source.log.last, 'ice sam: from the listener');
    expect(sam.music.hearing, isFalse);
    sam.ear.onState(true);
    expect(sam.music.hearing, isTrue);
    // Never to the DJ's own device.
    expect(maya.ears, isEmpty);
  });

  test('the queue goes on by itself, and everyone sees it', () async {
    final (maya, sam) = await playing();
    await maya.music.add(link(b));
    await sam.music.add('spotify:track:$c');
    await settle();
    expect([for (final s in sam.music.state!.next) s.song.track], [b, c]);
    await maya.look();
    expect(sam.music.state!.now!.song.title, 'Title of $a', reason: 'Spotify itself said');
    maya.spotify.to(199);
    await maya.look(seconds: 199);
    maya.spotify.doing = const SpotifyNow(state: 'playing', uri: 'spotify:track:9n3Ppam7vgaVa1iaRUc9Lp', length: Duration(seconds: 90));
    await maya.look();
    expect(maya.spotify.log, ['play $a', 'play $b']);
    expect(sam.music.state!.now!.song.track, b);
    // Anyone who may speak: skip, pause, play, move; each does it at the DJ's.
    sam.music.pause();
    await settle();
    expect(maya.spotify.log.last, 'pause');
    expect(sam.music.state!.playing, isFalse);
    sam.music.toggle();
    await settle();
    expect(maya.spotify.log.last, 'resume');
    sam.music.skip();
    await settle();
    expect(maya.spotify.log.last, 'play $c');
    // At the last one's end there is nothing more: Spotify is paused, and it is said.
    await maya.look();
    maya.spotify.to(199);
    await maya.look(seconds: 199);
    maya.spotify.doing = const SpotifyNow(state: 'playing', uri: 'spotify:track:9n3Ppam7vgaVa1iaRUc9Lp', length: Duration(seconds: 90));
    await maya.look();
    expect(maya.spotify.log.last, 'pause');
    expect(sam.music.state!.now, isNull);
  });

  test('someone takes away their own, the DJ anything; moving is anyone\'s', () async {
    final (maya, sam) = await playing();
    await maya.music.add(link(b));
    await sam.music.add(link(c));
    await settle();
    final mine = sam.music.state!.next[1], hers = sam.music.state!.next[0];
    expect(sam.music.mayRemove(hers), isFalse);
    expect(sam.music.mayRemove(mine), isTrue);
    sam.music.remove(hers.id);
    await settle();
    expect(sam.music.state!.next, hasLength(2), reason: 'not his to take away');
    sam.music.move(mine.id, 0);
    await settle();
    expect([for (final s in maya.music.state!.next) s.song.track], [c, b]);
    sam.music.remove(mine.id);
    await settle();
    maya.music.remove(hers.id);
    await settle();
    expect(sam.music.state!.next, isEmpty);
  });

  test('one DJ a call: the first stays, a second\'s state is not taken, and they may start once the first stops or leaves', () async {
    final (maya, sam) = await playing();
    final zoe = device('zoe');
    await zoe.join();
    await settle();
    expect(zoe.music.dj, 'maya', reason: 'told as they came in');
    expect(await zoe.music.start(), isFalse, reason: 'someone is playing');
    // A build that says it all the same.
    maya.now = sam.now = zoe.now = maya.now.add(const Duration(minutes: 1));
    zoe.session.sayMusic({'k': 'state', ...MusicState(next: const [], at: zoe.now).toWire()});
    await settle();
    expect(sam.music.dj, 'maya');
    expect(maya.music.mine, isTrue);
    // Nor are its offers: only the DJ's link is ever taken.
    final before = sam.ears.length;
    zoe.session.sayMusic({'k': 'offer', 'to': 'sam', 'l': 'x', 'sdp': 'theirs'});
    zoe.session.sayMusic({'k': 'stop'});
    await settle();
    expect(sam.ears.length, before);
    expect(sam.music.dj, 'maya');
    // The DJ leaves: nobody plays, and another can.
    await maya.leave();
    expect(sam.music.dj, isNull);
    expect(sam.ears.last.closed, isTrue);
    expect(await zoe.music.start(), isTrue);
    await settle();
    expect(sam.music.dj, 'zoe');
  });

  test('two who start at once settle it by their ids', () async {
    final maya = device('maya'), zoe = device('zoe'), sam = device('sam', computer: false);
    await maya.join();
    await zoe.join();
    await sam.join();
    final both = await Future.wait([zoe.music.start(), maya.music.start()]);
    await settle();
    expect(both.where((x) => x), isNotEmpty);
    expect([maya.music.mine, zoe.music.mine], [true, false], reason: 'the lower id stays');
    await maya.music.add(link(a));
    await settle();
    expect(zoe.music.dj, 'maya');
    expect(sam.music.dj, 'maya');
    expect(zoe.source.begun, isFalse);
  });

  test('who may not speak chooses nothing: not here, and not at the DJ\'s whatever their app says', () async {
    final (maya, sam) = await playing();
    for (final d in [maya, sam]) {
      d.mayNot.add('sam');
    }
    expect(sam.music.mayChoose, isFalse);
    expect(await sam.music.add(link(b)), contains('can\'t speak'));
    sam.music.skip();
    sam.session.sayMusic({'k': 'do', 'to': 'maya', 'w': 'skip'});
    sam.session.sayMusic({'k': 'do', 'to': 'maya', 'w': 'add', 'x': const Song(track: b).toWire()});
    await settle();
    expect(maya.spotify.log, ['play $a']);
    expect(maya.music.state!.next, isEmpty);
    // They still hear it (a stage's listener).
    expect(sam.ears.last.closed, isFalse);
    // The DJ muted for everyone: their music stops.
    maya.mayNot.add('maya');
    maya.session.setMuted(true);
    await settle();
    expect(maya.music.mine, isFalse);
    expect(maya.source.begun, isFalse);
    expect(sam.music.dj, isNull);
    expect(await maya.music.start(), isFalse);
  });

  test('a DJ who may no longer speak, their microphone off already, stops at the next look; and a listener lets go of theirs', () async {
    final (maya, sam) = await playing();
    maya.session.setMuted(true);
    await settle();
    expect(maya.music.mine, isTrue, reason: 'muting their own microphone is nothing to the music');
    sam.mayNot.add('maya');
    maya.now = maya.now.add(const Duration(seconds: 5));
    maya.spotify.to(50);
    await maya.look();
    expect(sam.music.dj, isNull);
    expect(sam.ears.last.closed, isTrue);
    maya.mayNot.add('maya');
    await maya.look();
    expect(maya.music.mine, isFalse);
    expect(maya.source.begun, isFalse);
  });

  test('off in the circle, nothing is said, taken or sent, on either side', () async {
    final (maya, sam) = await playing();
    sam.on = false;
    sam.session.setMuted(true);
    await settle();
    expect(sam.music.dj, isNull);
    expect(sam.ears.last.closed, isTrue);
    expect(await sam.music.add(link(b)), isNotNull);
    maya.on = false;
    sam.session.sayMusic({'k': 'do', 'to': 'maya', 'w': 'skip'});
    sam.session.sayMusic({'k': 'ask', 'to': 'maya', 'n': 0});
    await settle();
    expect(maya.spotify.log, ['play $a']);
    maya.session.setMuted(true);
    await settle();
    expect(maya.music.mine, isFalse);
    expect(maya.source.begun, isFalse);
    expect(await maya.music.start(), isFalse);
    // A build whose circle has it on says a state to one whose circle does not.
    maya.session.sayMusic({'k': 'state', ...MusicState(next: const [], at: maya.now).toWire()});
    await settle();
    expect(sam.music.dj, isNull);
  });

  test('nothing hostile from the room reaches Spotify, or anything else', () async {
    final (maya, sam) = await playing();
    final before = maya.spotify.log.length;
    for (final x in [
      {'t': '$a" & (do shell script "open -a Calculator") & "'},
      {'t': 'spotify:track:$a'},
      {'t': ['x']},
      {'t': a.substring(1)},
      7,
      null,
      {'n': 'No id'},
    ]) {
      sam.session.sayMusic({'k': 'do', 'to': 'maya', 'w': 'add', 'x': x});
    }
    for (final m in [
      {'k': 'do', 'to': 'maya', 'w': 'rm', 'e': 'x'},
      {'k': 'do', 'to': 'maya', 'w': 'mv', 'e': 1, 'i': '0'},
      {'k': 'do', 'to': 'maya', 'w': 'shell'},
      {'k': 7},
      {'k': 'ans', 'to': 'maya', 'sdp': 'not for this link', 'l': 'nope'},
      {'k': 'ans', 'to': 'maya', 'sdp': 7},
      {'k': 'ice', 'to': 'maya', 'l': 'nope', 'c': {'candidate': 'x'}},
      {'k': 'ice', 'to': 'maya', 'c': 7},
    ]) {
      sam.session.sayMusic(m);
    }
    final log = maya.source.log.length;
    await settle();
    expect(maya.spotify.log, hasLength(before));
    expect(maya.music.state!.next, isEmpty);
    expect(maya.source.log, hasLength(log), reason: 'nothing for a link that is not theirs');
    // A song with quotes in its name is only ever words.
    sam.now = maya.now = maya.now.add(const Duration(minutes: 1));
    sam.session.sayMusic({'k': 'do', 'to': 'maya', 'w': 'add', 'x': {'t': b, 'n': '" & (do shell script "x") & "'}});
    await settle();
    expect(maya.music.state!.next.single.song.title, '" & (do shell script "x") & "');
    maya.music.skip();
    await settle();
    expect(maya.spotify.log.last, 'play $b');
    // Asking for things without end is not heeded without end.
    final at = maya.spotify.log.length;
    for (var i = 0; i < 200; i++) {
      sam.session.sayMusic({'k': 'do', 'to': 'maya', 'w': i.isEven ? 'pause' : 'play'});
    }
    await settle();
    expect(maya.spotify.log.length - at, lessThanOrEqualTo(SpotifyMusic.asksMost));
    // Nor are more connections made than one every couple of seconds.
    final links = maya.source.log.where((l) => l.startsWith('offer sam')).length;
    maya.now = maya.now.add(const Duration(minutes: 1));
    for (var i = 0; i < 50; i++) {
      sam.session.sayMusic({'k': 'ask', 'to': 'maya', 'n': 1 << 40});
    }
    await settle();
    expect(maya.source.log.where((l) => l.startsWith('offer sam')).length, links + 1);
    // A description too long to be one is not taken.
    sam.session.sayMusic({'k': 'ans', 'to': 'maya', 'l': 'x' * 16, 'sdp': 'v' * 30000});
    await settle();
    expect(maya.source.log.where((l) => l.contains('vvvv')), isEmpty);
  });

  test('someone who comes in late is told what plays and sent the music', () async {
    final (maya, _) = await playing();
    await maya.look(seconds: 2);
    final late = device('late', computer: false);
    await late.join();
    await settle();
    expect(late.music.dj, 'maya');
    expect(late.music.state!.now!.song.track, a);
    expect(late.ears, hasLength(1));
    expect(maya.source.links, {'sam', 'late'});
    // Gone, their connection goes.
    await late.leave();
    expect(maya.source.links, {'sam'});
  });

  test('a listener whose connection drops asks again, and gets a new one; the relay first, then every path', () async {
    final (maya, sam) = await playing();
    maya.relay = true;
    final first = sam.ear..onState(true);
    expect(sam.music.hearing, isTrue);
    maya.now = maya.now.add(const Duration(seconds: 5));
    first.onState(false);
    await settle();
    expect(first.closed, isTrue);
    expect(sam.ears, hasLength(2));
    expect(sam.ear.relayOnly, isTrue, reason: 'the first try is through the relay, as a call\'s is');
    expect(maya.source.log.last, 'answer sam: answer to offer for sam');
    maya.now = maya.now.add(const Duration(seconds: 5));
    sam.ear.onState(false);
    await settle();
    expect(sam.ears.last.closed, isTrue);
    // The next time it asks (it waits longer each time) it is its second try: every path at once.
    sam.session.sayMusic({'k': 'ask', 'to': 'maya', 'n': 1});
    await settle();
    expect(sam.ears, hasLength(3));
    expect(sam.ear.relayOnly, isFalse);
    // A word from the old one is nothing to the new.
    first.onState(true);
    expect(sam.music.hearing, isFalse);
    // The DJ's side failing closes it there; the listener asks when it notices.
    maya.source.onState!('sam', 'failed');
    await settle();
    expect(maya.source.links, isEmpty);
  });

  test('how loud it is: the DJ\'s from its source, a listener\'s from its connection, read only while shown, seen and playing', () async {
    final (maya, sam) = await playing();
    sam.ear.loud = 0.8;
    maya.source.loud = 0.6;
    Future<void> beat() async {
      await Future<void>.delayed(SpotifyMusic.levelEvery * 2);
      await settle();
    }

    await beat();
    expect(sam.ear.levelsAsked, 0, reason: 'nothing shows it');
    void shown() {}
    sam.music.levels.addListener(shown);
    maya.music.levels.addListener(shown);
    addTearDown(() {
      sam.music.levels.removeListener(shown);
      maya.music.levels.removeListener(shown);
      AppSeen.set(true);
    });
    await beat();
    expect(sam.music.levels.value[SpotifyMusic.levelId], closeTo(0.4, 0.001));
    expect(maya.music.levels.value[SpotifyMusic.levelId], closeTo(0.3, 0.001));
    AppSeen.set(false);
    final asked = sam.ear.levelsAsked;
    await beat();
    expect(sam.music.levels.value, isEmpty);
    expect(sam.ear.levelsAsked, lessThanOrEqualTo(asked + 1), reason: 'not read while the app is put away');
    AppSeen.set(true);
    await beat();
    expect(sam.music.levels.value[SpotifyMusic.levelId], greaterThan(0));
    sam.music.levels.removeListener(shown);
    expect(sam.music.levels.value, isEmpty);
    await maya.music.stop();
    await settle();
    expect(maya.music.levels.value, isEmpty, reason: 'stopped');
  });

  test('its own loudness, kept here; at nothing it is not asked for; deafened it is silent', () async {
    final (_, sam) = await playing();
    expect(sam.ear.volume, closeTo(0.6, 0.001));
    sam.music.setVolume(25);
    expect(sam.ear.volume, closeTo(0.25, 0.001));
    expect(sam.app.choice(SpotifyMusic.volumeKey, ''), '25');
    sam.session.setDeafened(true);
    await settle();
    expect(sam.ear.silent, isTrue);
    sam.session.setDeafened(false);
    await settle();
    expect(sam.ear.silent, isFalse);
    // Muting the microphone has nothing to do with it.
    sam.session.setMuted(true);
    await settle();
    expect(sam.ear.silent, isFalse);
    final was = sam.ear;
    sam.music.setVolume(0);
    await settle();
    expect(was.closed, isTrue);
    expect(sam.music.hearing, isFalse);
  });

  test('what is wrong with Spotify is said in plain words, here and to the others', () async {
    final maya = device('maya'), sam = device('sam', computer: false);
    await maya.join();
    await sam.join();
    maya.spotify.running = false;
    expect(await maya.music.start(), isFalse);
    expect(maya.music.startWords, contains('isn\'t open'));
    maya.spotify.installed = false;
    expect(await maya.music.start(), isFalse);
    expect(maya.music.startWords, contains('isn\'t on this Mac'));
    maya.spotify
      ..installed = true
      ..running = true
      ..system = false;
    await maya.music.start();
    expect(maya.music.startWords, contains('macOS 14.4'));
    maya.spotify
      ..system = true
      ..refuse = 'denied';
    await maya.music.start();
    expect(maya.music.startWords, contains('Automation'));
    expect(maya.source.begun, isFalse);
    maya.spotify.refuse = null;
    maya.source.refuse = 'sound';
    await maya.music.start();
    expect(maya.music.startWords, contains('sound'));
    expect(maya.spotify.log, isEmpty, reason: 'nothing was pressed in Spotify by any of it');
    maya.source.refuse = null;
    expect(await maya.music.start(), isTrue);
    expect(maya.music.startWords, isNull);
    await maya.music.add(link(a));
    await settle();
    // Closed in the middle.
    maya.spotify.running = false;
    maya.spotify.onQuit!();
    await settle();
    expect(sam.music.state!.trouble, 'closed');
    expect(sam.music.state!.playing, isFalse);
    expect(sam.music.troubleWords, contains('closed on their computer'));
    await maya.look();
    expect(maya.music.state!.now!.song.track, a, reason: 'the queue is kept');
    maya.spotify.running = true;
    await maya.look();
    expect(sam.music.state!.trouble, '');
    // Nothing but silence, though it says it plays: the system said no to its sound, or it plays elsewhere.
    maya.spotify.to(5);
    maya.source.loud = 0;
    for (var i = 0; i < SpotifyMusic.silentAfter + 1; i++) {
      maya.spotify.to(6 + i);
      await maya.look();
    }
    expect(sam.music.state!.trouble, 'silent');
    expect(maya.music.troubleWords, contains('System Audio Recording'));
    maya.source.loud = 0.2;
    await maya.look();
    expect(sam.music.state!.trouble, '');
  });

  test('stopping pauses a song of the queue\'s, and leaves one the DJ chose themselves', () async {
    final (maya, sam) = await playing();
    await maya.look();
    await maya.music.stop();
    await settle();
    expect(maya.spotify.log.last, 'pause');
    expect(maya.source.begun, isFalse);
    expect(sam.music.dj, isNull);
    expect(sam.ear.closed, isTrue);
    // What they had on already is what is heard, and is theirs.
    maya.spotify.doing = const SpotifyNow(state: 'playing', uri: 'spotify:track:$c', title: 'Theirs', length: Duration(seconds: 100), position: Duration(seconds: 20));
    await maya.music.start();
    await settle();
    expect(sam.music.state!.now!.song.title, 'Theirs');
    expect(sam.music.state!.now!.by, 'maya');
    final pressed = maya.spotify.log.length;
    await maya.music.stop();
    expect(maya.spotify.log, hasLength(pressed));
    // Leaving the call ends all of it.
    await maya.music.start();
    await maya.leave();
    expect(maya.source.begun, isFalse);
    expect(maya.spotify.onQuit, isNull);
  });

  test('left while macOS was asking: nothing is begun', () async {
    final maya = device('maya');
    await maya.join();
    final started = maya.music.start();
    maya.music.followSession(null);
    expect(await started, isFalse);
    expect(maya.source.begun, isFalse);
    expect(maya.music.mine, isFalse);
  });

  test('a build from before it ignores it, and is in the call as ever', () async {
    final maya = device('maya');
    await maya.join();
    // No SpotifyMusic follows this one: as a build without it, 'mu' is nothing to it.
    final old = VoiceSession(channel: channel, route: FakeRoute(hub, 'old'), media: FakeMedia(), name: 'Old');
    await old.join();
    await settle();
    await maya.music.start();
    await maya.music.add(link(a));
    await settle();
    expect(old.members.keys, ['maya']);
    expect(maya.session.members.keys, ['old']);
    expect(maya.source.links, isEmpty, reason: 'it never asks');
    await old.leave();
  });

  test('a song added where its name couldn\'t be read is named by the DJ\'s device', () async {
    final (maya, sam) = await playing();
    maya.music.lookUp = (id) async => Song(track: id, title: 'Read by the DJ');
    await sam.music.add(link(b));
    await settle();
    expect(sam.music.state!.next.single.song.title, 'Read by the DJ');
  });

  test('what is said is sealed as everything in the call is, and fits one packet', () async {
    final (maya, sam) = await playing();
    final s = MusicState(next: [for (var i = 1; i <= songsMost; i++) QueuedSong(id: i, song: Song(track: a, title: 'x' * 70, artist: 'y' * 50, cover: 'a' * 40), by: 'maya')], at: maya.now);
    final sealed = NetCrypto.seal(channel.key, utf8.encode(jsonEncode({'t': 'mu', 'k': 'state', ...s.toWire()})));
    expect(sealed.length, lessThan(64 * 1024));
    expect(sam.said.first.m['t'], 'mu');
  });

  // --- a PC ----------------------------------------------------------------------------------------------------------------

  group('a PC\'s half, against a stand-in for the native one', () {
    final calls = <String>[];
    List<Object?> sessions = [];
    Object? refuse;
    var running = true;

    setUp(() {
      calls.clear();
      sessions = [];
      refuse = null;
      running = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SpotifyChannel.channel, (call) async {
        if (call.method != 'able' && refuse != null) throw PlatformException(code: '$refuse');
        calls.add('${call.method}${call.arguments == null ? '' : ' ${call.arguments}'}');
        return switch (call.method) {
          'able' => {'system': true, 'installed': true, 'running': running},
          'now' => running ? sessions : throw PlatformException(code: 'closed'),
          'begin' => 'track-1',
          'level' => 0.4,
          _ => null,
        };
      });
    });
    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SpotifyChannel.channel, null));

    Map<String, Object?> session(String app, String title, {String state = 'playing', int position = 0, int length = 200000}) => {'app': app, 'state': state, 'name': title, 'artist': 'Someone', 'position': position, 'length': length};

    test('another player\'s session is never read', () async {
      sessions = [session('chrome.exe', 'A private video')];
      expect((await WindowsSpotify.instance.now()).title, '');
      sessions = [session('chrome.exe', 'A private video'), session('Spotify.exe', 'The One', position: 5000)];
      final now = await WindowsSpotify.instance.now();
      expect(now.title, 'The One');
      expect(now.position, const Duration(seconds: 5));
      sessions = [session('SpotifyAB.SpotifyMusic_zpdnekdrzrea0!Spotify', 'From the Store')];
      expect((await WindowsSpotify.instance.now()).title, 'From the Store');
      // Nothing said to be an id is believed there.
      sessions = [
        {...session('Spotify.exe', 'The One'), 'id': 'spotify:track:$a'},
      ];
      expect((await WindowsSpotify.instance.now()).track, isNull);
    });

    test('only a track\'s id is ever opened, and nothing while Spotify is closed', () async {
      await WindowsSpotify.instance.play(a);
      expect(calls.last, 'play {id: $a}');
      calls.clear();
      for (final bad in ['', 'x', '$a&calc.exe', '${a.substring(1)} ', 'spotify:track:$a']) {
        await expectLater(WindowsSpotify.instance.play(bad), throwsA(isA<SpotifyRefused>()));
      }
      expect(calls, isEmpty);
      running = false;
      await expectLater(WindowsSpotify.instance.play(a), throwsA(isA<SpotifyRefused>().having((e) => e.word, 'word', 'closed')));
      expect(calls.where((c) => c.startsWith('play')), isEmpty, reason: 'opening its address would open Spotify');
      await expectLater(WindowsSpotify.instance.now(), throwsA(isA<SpotifyRefused>().having((e) => e.word, 'word', 'closed')));
    });

    test('what the native half refuses is its own kind, and anything unknown is Spotify not answering', () async {
      for (final (code, word) in [('closed', 'closed'), ('denied', 'denied'), ('sound', 'sound'), ('system', 'system'), ('0x80070005', 'failed')]) {
        refuse = code;
        await expectLater(WindowsSpotify.instance.pause(), throwsA(isA<SpotifyRefused>().having((e) => e.word, 'word', word)));
      }
    });

    test('the music\'s track asks for just the processing the microphone has, so it is never switched off by it', () async {
      final m = WindowsMusic(const VoiceSettings());
      await m.begin();
      final s = const VoiceSettings();
      expect(calls.single, 'begin {echo: ${s.useEcho}, noise: ${s.noiseOn(VoiceFx.available) == NoiseMode.webrtc}, gain: ${s.useGain}}');
      expect(await m.level(), 0.4);
      await m.end();
      expect(calls.last, 'end');
      expect(await m.offer('sam', servers: const [], relayOnly: false, lossless: false), isNull, reason: 'ended');
      refuse = 'sound';
      await expectLater(m.begin(), throwsA(isA<SpotifyRefused>().having((e) => e.word, 'word', 'sound')));
    });

    test('a PC as the DJ: shown and not started is said, and play there goes on', () async {
      final win = device('win', mac: false), sam = device('sam', computer: false);
      await win.join();
      await sam.join();
      // Spotify on a PC: no id, and a song opened is only shown.
      win.spotify.doing = const SpotifyNow(state: 'paused', title: 'Before', artist: 'Someone', length: Duration(seconds: 100), position: Duration(seconds: 30));
      expect(await win.music.start(), isTrue);
      win.music.lookUp = (id) async => Song(track: id, title: 'The One');
      SpotifyNow shown(String title, int s, String state) => SpotifyNow(state: state, title: title, artist: 'Someone', length: const Duration(seconds: 100), position: Duration(seconds: s));
      await win.music.add(link(a));
      await settle();
      expect(win.spotify.log, ['play $a']);
      win.spotify.doing = shown('The One', 0, 'paused');
      await win.look(seconds: 2);
      await win.look(seconds: 2);
      expect(win.spotify.log, ['play $a', 'resume'], reason: 'asked to play, once');
      win.spotify.doing = shown('The One', 0, 'paused');
      await win.look(seconds: 6);
      expect(sam.music.state!.trouble, 'unstarted');
      expect(win.music.troubleWords, 'Spotify opened but didn\'t start the song. Press play on it there.');
      win.spotify.doing = shown('The One', 1, 'playing');
      await win.look();
      expect(sam.music.state!.trouble, '');
      expect(sam.music.state!.playing, isTrue);
      expect(sam.music.state!.now!.song.track, a);
      // Closed in the middle of it.
      win.spotify.running = false;
      await win.look();
      expect(sam.music.state!.trouble, 'closed');
      expect(win.music.troubleWords, contains('Open Spotify'));
      expect(win.music.state!.now!.song.track, a);
    });
  });
}
