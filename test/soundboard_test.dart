import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/files/files_model.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/plugins/soundboard.dart';
import 'package:ghost_messaging/ui/common.dart';
import 'package:ghost_messaging/ui/soundboard_screen.dart';
import 'package:ghost_messaging/voice/soundboard.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'package:glacier/glacier.dart' show GlacierSwitch;

import 'support/space_call_harness.dart';

/// The Soundboard plugin (Matt, 2026-11-20: "build a soundboards plugin for circles"): lib/voice/soundboard.dart,
/// lib/plugins/soundboard.dart and lib/ui/soundboard_screen.dart. A hub and WebRTC stood in for, as
/// voice_channels_test.dart does; a player that only keeps what it was asked to play. Pictures: test/shots/soundboard-*
/// (--update-goldens).
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

class _Media implements VoiceMedia {
  @override
  final ValueNotifier<Map<String, double>> levels = ValueNotifier(const {});
  final log = <String>[];
  bool started = false, isMuted = false, isDeaf = false, isVideo = false;
  @override
  Future<void> start() async => started = true;
  @override
  Future<void> stop() async => started = false;
  @override
  set muted(bool on) => isMuted = on;
  @override
  set deafened(bool on) => isDeaf = on;
  @override
  Future<void> setVideo(bool on) async => isVideo = on;
  @override
  VoicePeer peer(String id, {required void Function(Map<String, dynamic> candidate) onCandidate}) => _Peer(this, id, onCandidate);
  @override
  void setPeerVolume(String id, double volume) {}
  @override
  void setPeerMuted(String id, bool muted) {}
}

class _Peer implements VoicePeer {
  _Peer(this.media, this.id, this.onCandidate);
  final _Media media;
  final String id;
  final void Function(Map<String, dynamic>) onCandidate;
  static const _opus = 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\na=fmtp:111 minptime=10;useinbandfec=1\r\n';
  @override
  Future<String> makeOffer() async {
    media.log.add('offer to $id');
    onCandidate({'candidate': 'c-from-offerer'});
    return _opus;
  }

  @override
  Future<String> takeOffer(String sdp) async {
    media.log.add('answer $id${sdp.contains('maxaveragebitrate=510000') ? ' (510k)' : ''}');
    return _opus;
  }

  @override
  Future<void> takeAnswer(String sdp) async => media.log.add('took answer from $id${sdp.contains('stereo=1') ? ' (stereo)' : ''}');
  @override
  Future<void> addCandidate(Map<String, dynamic> candidate) async => media.log.add('candidate from $id');
  @override
  Future<void> close() async => media.log.add('closed $id');
}

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}


/// What a device was asked to play, and how loud.
class _Played {
  final log = <String>[];
  Future<void> play(String path, double volume) async => log.add('$path ${volume.toStringAsFixed(2)}');
  Future<String> locate(BoardSound s, VoiceChannel? space) async => s.builtIn ? 'app:${s.id}' : 'circle:${s.name}';
}

SpaceFile _file(String id, {int size = 4000, String name = 'sound.mp3'}) =>
    SpaceFile.fromJson({'id': id, 'n': name, 'z': size, 'm': 'audio/mpeg', 'h': 'ab' * 32, 'k': base64Encode(List.filled(32, 7)), 'p': base64Encode(List.filled(8, 1)), 'u': 'Book club', 'at': 1}, by: 'x')!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null));
  tearDown(() async {
    Circles.instance.signerOverride = null;
    await Circles.instance.clear();
  });

  test('a pad pressed is said to the call, and each device plays its own copy at its own loudness', () async {
    final hub = _Hub();
    final c = VoiceChannel.make('Friday games');
    final maya = VoiceSession(channel: c, route: _Route(hub, 'maya-id'), media: _Media(), name: 'Maya');
    final sam = VoiceSession(channel: c, route: _Route(hub, 'sam-id'), media: _Media(), name: 'Sam');
    await maya.join();
    await sam.join();
    await _settle();
    final hers = _Played(), his = _Played();
    final samApp = AppState();
    final a = Soundboard.forTest(isOn: () => true, player: hers.play, locate: hers.locate, app: AppState())..followSession(maya);
    final b = Soundboard.forTest(isOn: () => true, player: his.play, locate: his.locate, app: samApp)..followSession(sam);
    final horn = builtInSounds.firstWhere((s) => s.id == 'airhorn');

    expect(a.press(horn), isNull);
    await _settle();
    expect(hers.log, ['app:airhorn 0.70'], reason: 'whoever pressed hears it too');
    expect(his.log, ['app:airhorn 0.70'], reason: 'Sam\'s own copy: nothing but the id was said');
    expect(b.last!.by, 'maya-id');
    expect(b.last!.sound.name, 'Air horn');
    expect(a.last!.by, 'me');

    // Sam turns it down: his alone.
    b.setVolume(25);
    a.press(builtInSounds.firstWhere((s) => s.id == 'ding'));
    await _settle();
    expect(his.log.last, 'app:ding 0.25');
    expect(hers.log.last, 'app:ding 0.70');

    // A sound no list here has is not played, whatever is said: nobody plays a file at anyone.
    his.log.clear();
    maya.saySound('0123456789abcdef0123456789abcdef');
    maya.saySound('../../etc/passwd');
    await _settle();
    expect(his.log, isEmpty);

    // Hearing none of it: shown, not played. His own pads still play here.
    b.setQuiet(true);
    a.press(horn);
    await _settle();
    expect(his.log, isEmpty);
    expect(b.last!.sound.id, 'airhorn', reason: 'still shown who played what');
    b.press(horn);
    await _settle();
    expect(his.log, ['app:airhorn 0.25']);
    b.setQuiet(false);

    // Deafened: nothing of the call is heard, the soundboard with it.
    his.log.clear();
    sam.setDeafened(true);
    a.press(horn);
    await _settle();
    expect(his.log, isEmpty);
    sam.setDeafened(false);

    // The plugin off here: not played, and not shown.
    final off = Soundboard.forTest(isOn: () => false, player: his.play, locate: his.locate, app: samApp);
    b.followSession(null);
    off.followSession(sam);
    a.press(horn);
    await _settle();
    expect(his.log, isEmpty);
    expect(off.last, isNull);

    off.followSession(null);
    a.followSession(null);
    expect(a.last, isNull);
    await maya.leave();
    await sam.leave();
  });

  test('nobody plays more than a burst: this device stops saying them, another\'s stops playing them', () async {
    final hub = _Hub();
    final c = VoiceChannel.make('Friday games');
    final maya = VoiceSession(channel: c, route: _Route(hub, 'maya-id'), media: _Media(), name: 'Maya');
    final sam = VoiceSession(channel: c, route: _Route(hub, 'sam-id'), media: _Media(), name: 'Sam');
    await maya.join();
    await sam.join();
    await _settle();
    final hers = _Played(), his = _Played();
    final a = Soundboard.forTest(isOn: () => true, player: hers.play, locate: hers.locate, app: AppState())..followSession(maya);
    final b = Soundboard.forTest(isOn: () => true, player: his.play, locate: his.locate, app: AppState())..followSession(sam);
    final said = <String>[];
    final ding = builtInSounds.firstWhere((s) => s.id == 'ding');
    final answers = <String?>[];
    for (var i = 0; i < boardBurst + 3; i++) {
      answers.add(a.press(ding));
      await _settle();
    }
    expect(answers.where((x) => x == null).length, boardBurst);
    expect(answers.last, 'Give it a moment.');
    expect(his.log.length, boardBurst);

    // An app that says them anyway (not this one): played no more than the burst here.
    his.log.clear();
    b.followSession(null);
    b.followSession(sam);
    sam.onSound = (from, id) {
      said.add(id);
    };
    b.followSession(null);
    final again = Soundboard.forTest(isOn: () => true, player: his.play, locate: his.locate, app: AppState())..followSession(sam);
    for (var i = 0; i < 20; i++) {
      maya.saySound('ding');
    }
    await _settle();
    expect(his.log.length, boardBurst);
    again.followSession(null);
    a.followSession(null);
    await maya.leave();
    await sam.leave();
  });

  test('a circle\'s own sounds: added by whoever may change it, kept in its signed manifest, and the only files played', () async {
    final owner = NetKeys.generate(), member = NetKeys.generate();
    final dir = Directory.systemTemp.createTempSync('ghost-soundboard-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final lounge = CircleSpace(seed: '5c' * 32, name: 'Lounge');
    final base = CircleManifest(owner: NetCrypto.hex(owner.public), version: 1, name: 'Book club', spaces: [lounge]);
    final signer = KeysSigner(owner);
    final first = await base.signedBy(signer.id, signer.publicKey, signer.sign);
    final circle = Circle(seed: '5' * 64, owner: NetCrypto.hex(owner.public), manifest: first, mine: true);
    Circles.instance.signerOverride = signer;
    Circles.instance.join(circle);
    Circle now() => Circles.instance.bySeed(circle.seed)!;

    final played = _Played();
    var n = 0;
    final uploaded = <String>[];
    final board = Soundboard.forTest(
      isOn: () => true,
      player: played.play,
      locate: played.locate,
      app: AppState(),
      upload: (c, file, name) async {
        uploaded.add(name);
        return _file('${n++}'.padLeft(32, '0'), size: file.lengthSync(), name: name);
      },
    );
    final clip = File('${dir.path}/wow-what.mp3')..writeAsBytesSync(List.filled(4000, 1));
    expect(SoundNameScreen.nameOf(clip.path), 'Wow what');

    // What a clip may not be.
    final text = File('${dir.path}/notes.txt')..writeAsStringSync('hello');
    expect(await board.add(now(), path: text.path, name: 'Notes', emoji: '🔊'), contains('audio file'));
    final big = File('${dir.path}/long.mp3')..writeAsBytesSync(Uint8List(boardClipMost + 1));
    expect(await board.add(now(), path: big.path, name: 'Long', emoji: '🔊'), contains('too big'));
    expect(await board.add(now(), path: '${dir.path}/gone.mp3', name: 'Gone', emoji: '🔊'), contains('isn\'t there'));
    expect(uploaded, isEmpty);

    // Someone who may not change the circle adds nothing.
    Circles.instance.signerOverride = KeysSigner(member);
    expect(await board.add(now(), path: clip.path, name: 'Wow', emoji: '😂'), contains('Only whoever may change'));
    expect(uploaded, isEmpty);
    Circles.instance.signerOverride = signer;

    expect(await board.add(now(), path: clip.path, name: 'Wow', emoji: '😂'), isNull);
    expect(await board.add(now(), path: clip.path, name: '  Goat  ', emoji: '🐐'), isNull);
    expect(uploaded, ['sound.mp3', 'sound.mp3']);
    final own = circleSounds(now());
    expect([for (final s in own) '${s.emoji} ${s.name}'], ['😂 Wow', '🐐 Goat']);
    expect(now().manifest.isSigned, isTrue);
    // Adding its sounds does not turn the plugin on for the circle, nor off.
    expect(now().manifest.pluginOn('soundboard'), isFalse);
    expect(await Circles.instance.setPlugin(now(), 'soundboard', on: true), isTrue);
    expect(circleSounds(now()).length, 2, reason: 'turning it on keeps its sounds');

    // Read back from what goes between devices.
    final back = CircleManifest.fromJson(jsonDecode(jsonEncode(now().manifest.toJson())));
    expect(back, isNotNull);
    expect([for (final s in circleSounds(Circle(seed: circle.seed, owner: circle.owner, manifest: back!))) s.name], ['Wow', 'Goat']);

    // In a call in the circle's space: its sounds are pads, and the one said is the one played.
    final space = now().channelOf(lounge);
    expect([for (final s in board.soundsOf(space)) s.name].sublist(builtInSounds.length), ['Wow', 'Goat']);
    expect(board.soundsOf(VoiceChannel.make('Elsewhere')).length, builtInSounds.length, reason: 'a space outside the circle has the app\'s alone');
    final hub = _Hub();
    final maya = VoiceSession(channel: space, route: _Route(hub, 'maya-id'), media: _Media(), name: 'Maya');
    final sam = VoiceSession(channel: space, route: _Route(hub, 'sam-id'), media: _Media(), name: 'Sam');
    await maya.join();
    await sam.join();
    await _settle();
    board.followSession(sam);
    await _settle();
    played.log.clear();
    maya.saySound(own[1].id);
    await _settle();
    expect(played.log, ['circle:Goat 0.70']);

    // Named again, and taken away: then it is not played.
    expect(await board.rename(now(), own[1], name: 'The goat', emoji: '🔥'), isTrue);
    expect([for (final s in circleSounds(now())) '${s.emoji} ${s.name}'], ['😂 Wow', '🔥 The goat']);
    expect(await board.remove(now(), own[1]), isTrue);
    played.log.clear();
    maya.saySound(own[1].id);
    await _settle();
    expect(played.log, isEmpty);

    // No more than a circle may have.
    for (var i = circleSounds(now()).length; i < boardCircleMost; i++) {
      expect(await board.add(now(), path: clip.path, name: 'Sound $i', emoji: '🔊'), isNull);
    }
    expect(await board.add(now(), path: clip.path, name: 'One more', emoji: '🔊'), contains('at most $boardCircleMost'));
    expect(now().manifest.fitsAPacket, isTrue);

    board.followSession(null);
    await maya.leave();
    await sam.leave();
  });

  test('what a manifest says of a sound is taken with care', () {
    final f = _file('0123456789abcdef0123456789abcdef').toJson();
    expect(BoardSound.fromJson({'n': 'Wow', 'e': '😂', 'f': f})!.name, 'Wow');
    expect(BoardSound.fromJson({'n': 'x' * 200, 'e': '😂', 'f': f})!.name.length, BoardSound.nameMost);
    expect(BoardSound.fromJson({'n': 'Wow', 'e': 'a long word in place of a face', 'f': f})!.emoji, '🔊');
    expect(BoardSound.fromJson({'n': '  ', 'e': '😂', 'f': f}), isNull);
    expect(BoardSound.fromJson({'n': 'Wow', 'e': '😂'}), isNull);
    expect(BoardSound.fromJson({'n': 'Wow', 'e': '😂', 'f': _file('0123456789abcdef0123456789abcdef', size: boardClipMost + 1).toJson()}), isNull, reason: 'a clip bigger than one may be');
    expect(BoardSound.fromJson('airhorn'), isNull);
  });

  test('the plugin: for a device or a whole circle, in a call\'s menu and the header of the space whose call it is', () {
    const p = SoundboardPlugin();
    expect(shippedPlugins.whereType<SoundboardPlugin>().length, 1);
    expect(p.scopes, {PluginScope.device, PluginScope.circle});
    expect(p.onByDefault, isFalse);
    final reg = PluginRegistry([p]);
    expect(reg.circlePlugins, [p]);
    final store = MemoryStore();
    reg.setOn(p, store, true);
    List<String> header({required bool inCall, bool voice = true}) =>
        [for (final b in reg.actionsIn(Slots.spaceHeader, SpacePlace(space: 's', spaceName: 'Lounge', voice: voice, inCall: inCall), store)) b.action.label];
    expect(header(inCall: true), ['Soundboard']);
    expect(header(inCall: false), isEmpty);
    expect([for (final b in reg.actionsIn(Slots.callControls, const CallPlace(space: 's', spaceName: 'Lounge'), store)) b.action.label], ['Soundboard']);
    // In a circle's space it is the circle's word, not the device's.
    expect(reg.actionsIn(Slots.callControls, const CallPlace(space: 's', spaceName: 'Lounge', circle: 'c'), store, inCircle: true, circleOn: (_) => false), isEmpty);
    expect(reg.actionsIn(Slots.callControls, const CallPlace(space: 's', spaceName: 'Lounge', circle: 'c'), MemoryStore(), inCircle: true, circleOn: (_) => true).length, 1);
  });

  test('every pad of the app\'s own has its sound in the app', () {
    for (final s in builtInSounds) {
      final f = File(s.asset);
      expect(f.existsSync(), isTrue, reason: s.asset);
      final b = f.readAsBytesSync();
      expect(String.fromCharCodes(b.sublist(0, 4)), 'RIFF');
      expect(b.length, greaterThan(20000), reason: '${s.id} is a sound, not a stub');
    }
    expect({for (final s in builtInSounds) s.id}.length, builtInSounds.length);
    expect(File('pubspec.yaml').readAsStringSync(), contains('- assets/soundboard/'));
  });

  group('pictures', () {
    late Soundboard board;
    late _Played played;
    setUp(() {
      board = Soundboard.instance;
      played = _Played();
      board
        ..player = played.play
        ..locate = played.locate
        ..isOn = (() => true)
        ..app = AppState();
    });
    tearDown(() {
      board
        ..followSession(null)
        ..player = Soundboard.playClip
        ..locate = Soundboard.fileOf
        ..isOn = SoundboardPlugin.onInCall
        ..upload = Soundboard.uploadClip
        ..app = null;
    });

    testWidgets('the pads: the app\'s, the circle\'s, adding one, and what this device hears', (tester) async {
      final h = await SpaceHarness.load(tester);
      final owner = NetKeys.generate();
      final signer = KeysSigner(owner);
      final dir = Directory.systemTemp.createTempSync('ghost-soundboard-ui');
      addTearDown(() => dir.deleteSync(recursive: true));
      final clip = File('${dir.path}/vine-boom.mp3')..writeAsBytesSync(List.filled(4000, 1));
      final lounge = CircleSpace(seed: '5c' * 32, name: 'Lounge');
      final base = CircleManifest(owner: NetCrypto.hex(owner.public), version: 1, name: 'Book club', spaces: [lounge]);
      final sounds = [
        BoardSound(id: '1' * 32, name: 'Wow', emoji: '😂', file: _file('1' * 32)),
        BoardSound(id: '2' * 32, name: 'The goat', emoji: '🐐', file: _file('2' * 32)),
      ];
      final first = (await tester.runAsync(() => base.next(extra: base.withPlugin('soundboard', on: true, choices: {'snd': [for (final s in sounds) s.toJson()]})).signedBy(signer.id, signer.publicKey, signer.sign)))!;
      final circle = Circle(seed: '5' * 64, owner: NetCrypto.hex(owner.public), manifest: first, mine: true);
      Circles.instance.signerOverride = signer;
      Circles.instance.join(circle);
      var n = 3;
      board.upload = (c, file, name) async => _file('${n++}' * 32, size: file.lengthSync(), name: name);

      for (final dark in [false, true]) {
        await h.shoot(tester, SoundboardScreen(circle: circle, pickClip: () async => clip.path), 'soundboard-pads', dark: dark);
        expect(find.text('Air horn'), findsOneWidget);
        expect(find.text('The goat'), findsOneWidget);
        expect(find.text('Add a sound'), findsOneWidget);
      }
      // A pad tried from the circle's settings plays here, and is said to nobody.
      await tester.tap(find.byKey(const ValueKey('pad-airhorn')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(played.log, ['app:airhorn 0.70']);
      await tester.tap(find.byKey(ValueKey('pad-${'2' * 32}')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(played.log.last, 'circle:The goat 0.70');
      expect(board.last, isNull);

      // Adding one: the clip chosen, named from its file, given a face, and it is a pad.
      await tester.ensureVisible(find.byKey(const ValueKey('pad-add')));
      await tester.tap(find.byKey(const ValueKey('pad-add')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await h.again(tester, 'soundboard-name', dark: true);
      expect(find.text('Add a sound'), findsWidgets);
      expect(tester.widget<EditableText>(find.byType(EditableText)).controller.text, 'Vine boom');
      await tester.tap(find.byKey(const ValueKey('sound-emoji-💥')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('sound-save')));
      await tester.tap(find.byKey(const ValueKey('sound-save')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect([for (final s in circleSounds(Circles.instance.bySeed(circle.seed)!)) '${s.emoji} ${s.name}'], ['😂 Wow', '🐐 The goat', '💥 Vine boom']);
      expect(find.text('Vine boom'), findsOneWidget, reason: 'back on the pads, with the new one');

      // Hearing none of it, from the switch.
      await tester.pump(const Duration(seconds: 6)); // the toast gone from over it
      await tester.pump(const Duration(seconds: 1));
      await tester.ensureVisible(find.byKey(const ValueKey('soundboard-hear')));
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('soundboard-hear')), matching: find.byType(GlacierSwitch)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(board.quiet, isTrue);
      await tester.pump(const Duration(seconds: 7));
    });

    testWidgets('a member who may not change the circle has its pads and no way to add one; the line over a call', (tester) async {
      final h = await SpaceHarness.load(tester);
      final owner = NetKeys.generate(), me = NetKeys.generate();
      final signer = KeysSigner(owner);
      final lounge = CircleSpace(seed: '5c' * 32, name: 'Lounge');
      final base = CircleManifest(owner: NetCrypto.hex(owner.public), version: 1, name: 'Book club', spaces: [lounge]);
      final wow = BoardSound(id: '1' * 32, name: 'Wow', emoji: '😂', file: _file('1' * 32));
      final first = (await tester.runAsync(() => base.next(extra: base.withPlugin('soundboard', on: true, choices: {'snd': [wow.toJson()]})).signedBy(signer.id, signer.publicKey, signer.sign)))!;
      final circle = Circle(seed: '5' * 64, owner: NetCrypto.hex(owner.public), manifest: first);
      Circles.instance.signerOverride = KeysSigner(me);
      Circles.instance.join(circle);
      final space = Circles.instance.bySeed(circle.seed)!.channelOf(lounge);

      // In a call: a press is said, and the line over the call says who played what.
      final hub = _Hub();
      final mine = VoiceSession(channel: space, route: _Route(hub, me.id), media: _Media(), name: 'Me');
      final maya = VoiceSession(channel: space, route: _Route(hub, 'maya-id'), media: _Media(), name: 'Maya');
      final heard = <String>[];
      await tester.runAsync(() async {
        await mine.join();
        await maya.join();
        await _settle();
      });
      maya.onSound = (from, id) => heard.add(id);
      board.followSession(mine);
      await h.shoot(tester, GhostPage(title: 'Lounge', body: Column(children: [const SoundPlayedLine(), Expanded(child: SoundboardScreen(space: space))])), 'soundboard-call');
      expect(find.text('Wow'), findsOneWidget);
      expect(find.text('Add a sound'), findsNothing);
      expect(find.byKey(const ValueKey('sound-played')), findsNothing);
      await tester.tap(find.byKey(ValueKey('pad-${'1' * 32}')));
      await tester.runAsync(_settle);
      await h.again(tester, 'soundboard-call-played');
      expect(heard, ['1' * 32]);
      expect(find.text('You played Wow'), findsOneWidget);
      expect(played.log, ['circle:Wow 0.70']);
      // It goes by itself.
      await tester.pump(Soundboard.shownFor + const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('sound-played')), findsNothing);
      board.followSession(null);
      await tester.runAsync(() async {
        await mine.leave();
        await maya.leave();
      });
      await tester.pump(const Duration(seconds: 7));
    });
  });
}
