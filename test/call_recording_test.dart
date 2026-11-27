import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/circles/circle.dart';
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/record_call.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/plugins/scribe.dart';
import 'package:ghost_messaging/voice/mp4_names.dart';
import 'package:ghost_messaging/voice/recorder.dart';
import 'package:ghost_messaging/voice/recording_playback.dart';
import 'package:ghost_messaging/voice/scribe.dart';
import 'package:ghost_messaging/net/hub_carrier.dart' show RoomEvent;
import 'package:ghost_messaging/voice/channels.dart';
import 'package:ghost_messaging/voice/voice.dart';

/// Recording a call (lib/voice/recorder.dart, lib/voice/mp4_names.dart, lib/plugins/record_call.dart; Matt,
/// 2026-11-19: "a "record call" plugin where it records the call to an MP4 with multiple named audio tracks", and
/// "Some plugins should be serverside / cirlce side as well").

Uint8List _box(String type, List<Uint8List> body) {
  final size = 8 + body.fold<int>(0, (n, b) => n + b.length);
  final b = BytesBuilder()
    ..add(Uint8List(4)..buffer.asByteData().setUint32(0, size))
    ..add(latin1.encode(type));
  for (final x in body) {
    b.add(x);
  }
  return b.toBytes();
}

Uint8List _bytes(List<int> l) => Uint8List.fromList(l);

/// A track as a muxer writes one: a header (version 0, enabled), a handler named SoundHandler, and one chunk offset.
Uint8List _trak(int id, int chunk) {
  final tkhd = ByteData(84)
    ..setUint32(0, 0x00000007)
    ..setUint32(12, id);
  final hdlr = BytesBuilder()
    ..add(Uint8List(4))
    ..add(Uint8List(4))
    ..add(latin1.encode('soun'))
    ..add(Uint8List(12))
    ..add(_bytes([...latin1.encode('SoundHandler'), 0]));
  final stco = ByteData(12)
    ..setUint32(4, 1)
    ..setUint32(8, chunk);
  return _box('trak', [
    _box('tkhd', [tkhd.buffer.asUint8List()]),
    _box('mdia', [
      _box('hdlr', [hdlr.toBytes()]),
      _box('minf', [
        _box('stbl', [_box('stco', [stco.buffer.asUint8List()])]),
      ]),
    ]),
  ]);
}

/// The tracks of a file as a reader finds them: each one's name boxes, handler name, flags, group and chunk offset.
List<Map<String, Object>> _read(Uint8List file) {
  Iterable<Uint8List> kids(Uint8List b, int from) sync* {
    final d = ByteData.sublistView(b);
    var at = from;
    while (at + 8 <= b.length) {
      final size = d.getUint32(at);
      yield Uint8List.sublistView(b, at, at + size);
      at += size;
    }
  }

  String type(Uint8List b) => latin1.decode(b.sublist(4, 8));
  Uint8List child(Uint8List b, String t, [int from = 8]) => kids(b, from).firstWhere((k) => type(k) == t);
  final moov = kids(file, 0).firstWhere((b) => type(b) == 'moov');
  return [
    for (final trak in kids(moov, 8).where((b) => type(b) == 'trak'))
      () {
        final tkhd = child(trak, 'tkhd');
        final hdlr = child(child(trak, 'mdia'), 'hdlr');
        final udta = child(trak, 'udta');
        final nam = child(udta, '©nam');
        final stco = child(child(child(child(trak, 'mdia'), 'minf'), 'stbl'), 'stco');
        return <String, Object>{
          'name': utf8.decode(child(udta, 'name').sublist(8)),
          'title': utf8.decode(nam.sublist(12)),
          'handler': utf8.decode(hdlr.sublist(32, hdlr.length - 1)),
          'enabled': tkhd[11] & 1 == 1,
          'group': ByteData.sublistView(tkhd).getUint16(8 + 4 + 20 + 8 + 2),
          'chunk': ByteData.sublistView(stco).getUint32(16),
        };
      }(),
  ];
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ghost-rec-'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('naming the tracks', () {
    test('the movie box last (as the platforms write it): each track named three ways, the mix alone enabled', () async {
      final ftyp = _box('ftyp', [latin1.encode('isom')]);
      final mdat = _box('mdat', [Uint8List(100)]);
      final at = ftyp.length + 8;
      final moov = _box('moov', [_box('mvhd', [Uint8List(100)]), _trak(1, at), _trak(2, at + 50), _trak(3, at + 70)]);
      final f = File('${dir.path}/a.mp4')..writeAsBytesSync([...ftyp, ...mdat, ...moov]);
      await Mp4Names.apply(f.path, ['Everyone', 'Maya', 'Sam Ó Riordáin']);
      final tracks = _read(f.readAsBytesSync());
      expect([for (final t in tracks) t['name']], ['Everyone', 'Maya', 'Sam Ó Riordáin']);
      expect([for (final t in tracks) t['title']], ['Everyone', 'Maya', 'Sam Ó Riordáin'], reason: 'libmpv, the app\'s player, reads ©nam as the title');
      expect([for (final t in tracks) t['handler']], ['Everyone', 'Maya', 'Sam Ó Riordáin']);
      expect([for (final t in tracks) t['enabled']], [true, false, false], reason: 'a player that plays one track plays the mix');
      expect([for (final t in tracks) t['group']], [1, 1, 1]);
      expect([for (final t in tracks) t['chunk']], [at, at + 50, at + 70], reason: 'the media did not move');
      expect(f.readAsBytesSync().sublist(ftyp.length, ftyp.length + mdat.length), mdat, reason: 'the media is never touched');
    });

    test('the movie box first: every chunk offset moves by however much the box grew', () async {
      final ftyp = _box('ftyp', [latin1.encode('isom')]);
      Uint8List moovAt(int at) => _box('moov', [_trak(1, at), _trak(2, at + 40)]);
      final first = moovAt(0);
      final at = ftyp.length + first.length + 8;
      final moov = moovAt(at);
      final mdat = _box('mdat', [Uint8List.fromList(List.generate(80, (i) => i))]);
      final f = File('${dir.path}/b.mp4')..writeAsBytesSync([...ftyp, ...moov, ...mdat]);
      await Mp4Names.apply(f.path, ['Everyone', 'Maya']);
      final out = f.readAsBytesSync();
      final tracks = _read(out);
      final media = out.length - mdat.length + 8;
      expect([for (final t in tracks) t['chunk']], [media, media + 40]);
      expect(out.sublist(out.length - mdat.length), mdat);
    });

    test('a file that is not an MP4 is refused, not spoilt', () async {
      final f = File('${dir.path}/c.mp4')..writeAsBytesSync(utf8.encode('not a movie at all, just words'));
      await expectLater(Mp4Names.apply(f.path, ['x']), throwsA(isA<FormatException>()));
      expect(f.readAsStringSync(), 'not a movie at all, just words');
    });

    // Matt, 2026-11-23: "i want to see the mixer when viewing sounds recordings but it just loads the media player
    // view": a recording opened from a Files space or a chat is a file like any other there, so it is known for a
    // recording by the names the recorder wrote in it.
    test('the names are read back from the file, and a call\'s recording is known by them', () async {
      CallRecorder.folderForTest = dir;
      RecordingPlayback.opensHereForTest = true;
      addTearDown(() {
        CallRecorder.folderForTest = null;
        RecordingPlayback.opensHereForTest = null;
      });
      final ftyp = _box('ftyp', [latin1.encode('isom')]);
      final mdat = _box('mdat', [Uint8List(100)]);
      final at = ftyp.length + 8;
      File mp4(String name, List<Uint8List> traks) => File('${dir.path}/$name')..writeAsBytesSync([...ftyp, ...mdat, ..._box('moov', [_box('mvhd', [Uint8List(100)]), ...traks])]);

      final rec = mp4('rec19a2b3c.mp4', [_trak(1, at), _trak(2, at + 50), _trak(3, at + 70)]);
      await Mp4Names.apply(rec.path, ['Everyone', 'Maya', 'Sam Ó Riordáin']);
      expect(await Mp4Names.tracks(rec.path), [(name: 'Everyone', kind: 'soun'), (name: 'Maya', kind: 'soun'), (name: 'Sam Ó Riordáin', kind: 'soun')]);
      final r = (await recordingIn(rec.path, id: 'file-0/7', space: 'Files'))!;
      expect(r.people, ['Maya', 'Sam Ó Riordáin'], reason: 'a voice each, after the mix');
      expect(r.path, rec.path);
      expect(r.id, 'file-0_7', reason: 'its id names a folder');
      expect(r.space, 'Files');

      // Any other MP4 is a video for the player: tracks no recorder named, or a picture among them.
      final clip = mp4('holiday.mp4', [_trak(1, at), _trak(2, at + 50)]);
      expect([for (final t in await Mp4Names.tracks(clip.path)) t.name], ['SoundHandler', 'SoundHandler'], reason: 'unnamed: the handler\'s own name');
      expect(await recordingIn(clip.path, id: 'a'), isNull);
      final film = mp4('film.mp4', [_trak(1, at), _trak(2, at + 50)]);
      await Mp4Names.apply(film.path, ['Everyone', 'Maya']);
      final bytes = film.readAsBytesSync();
      final soun = latin1.decode(bytes).lastIndexOf('soun');
      bytes.setRange(soun, soun + 4, latin1.encode('vide'));
      film.writeAsBytesSync(bytes);
      expect((await Mp4Names.tracks(film.path)).last.kind, 'vide');
      expect(await recordingIn(film.path, id: 'b'), isNull, reason: 'one with a picture plays in the player, which shows it');
      final words = File('${dir.path}/rec1.mp4')..writeAsStringSync('not a movie at all, just words');
      expect(await recordingIn(words.path, id: 'c'), isNull);
      await expectLater(Mp4Names.tracks(words.path), throwsA(isA<FormatException>()));

      // Where the device can't open one (a browser, Linux), nothing is a recording: it plays as before.
      RecordingPlayback.opensHereForTest = false;
      expect(await recordingIn(rec.path, id: 'd'), isNull);
      RecordingPlayback.opensHereForTest = true;

      // This device's own recording, come back from the space under its name: the one in its list, marks and all.
      final own = Recording(id: 'rec19a2b3c', path: '${dir.path}/kept.mp4', space: 'Lounge', at: DateTime(2026, 11, 23), seconds: 12, people: const ['Maya', 'Sam Ó Riordáin'], markers: const [3.5]);
      rec.copySync(own.path);
      CallRecorder.instance.keep(own);
      addTearDown(() => CallRecorder.instance.delete(own));
      final back = (await recordingIn(rec.path, id: 'e'))!;
      expect(back.id, 'rec19a2b3c');
      expect(back.markers, [3.5]);
      expect(back.path, own.path);

      // The name it goes up under, which is worth bringing down to look inside.
      expect(namedAsRecording('rec19a2b3c.mp4'), isTrue);
      expect(namedAsRecording('holiday.mp4'), isFalse);
      expect(namedAsRecording('record.mp4'), isFalse);
      expect(namedAsRecording('rec19a2b3c.mkv'), isFalse);
    });
  });

  test('the mix sums every voice, holds it under clipping, and runs as long as the longest', () async {
    Uint8List pcm(List<int> s) {
      final d = ByteData(s.length * 2);
      for (var i = 0; i < s.length; i++) {
        d.setInt16(i * 2, s[i], Endian.little);
      }
      return d.buffer.asUint8List();
    }

    final a = File('${dir.path}/a.pcm')..writeAsBytesSync(pcm([1000, -2000, 30000, 5]));
    final b = File('${dir.path}/b.pcm')..writeAsBytesSync(pcm([1000, -2000, 30000]));
    mixPcm([a.path, b.path], '${dir.path}/mix.pcm');
    final d = ByteData.sublistView(File('${dir.path}/mix.pcm').readAsBytesSync());
    expect([for (var i = 0; i < d.lengthInBytes ~/ 2; i++) d.getInt16(i * 2, Endian.little)], [2000, -4000, 32767, 5]);
  });

  group('a plugin a circle holds', () {
    const plugin = RecordCallPlugin();
    final registry = PluginRegistry(const [plugin]);

    test('off until added, and listed for circles', () {
      expect(plugin.onByDefault, isFalse);
      expect(plugin.scopes, containsAll([PluginScope.device, PluginScope.circle]));
      expect(registry.circlePlugins, [plugin]);
      expect(shippedPlugins.whereType<RecordCallPlugin>(), hasLength(1));
    });

    test('in a circle\'s space it is on as the circle says, whatever this device\'s switch; elsewhere as the switch says', () {
      final store = MemoryStore();
      expect(registry.isOnIn(plugin, store), isFalse);
      expect(registry.isOnIn(plugin, store, inCircle: true), isFalse, reason: 'a circle that said nothing has it off');
      expect(registry.isOnIn(plugin, store, inCircle: true, circleOn: true), isTrue, reason: 'on for everyone, though no one added it');
      registry.setOn(plugin, store, true);
      expect(registry.isOnIn(plugin, store), isTrue);
      expect(registry.isOnIn(plugin, store, inCircle: true, circleOn: false), isFalse, reason: 'the circle turned it off');
    });

    test('the circle\'s choice is kept in its manifest, and a manifest that keeps it unread passes it on as written', () {
      final m = CircleManifest(owner: '02${'ab' * 32}', name: 'Table', version: 3);
      expect(m.pluginOn('recordcall'), isNull);
      final on = m.next(extra: m.withPlugin('recordcall', on: true));
      expect(on.pluginOn('recordcall'), isTrue);
      // An older build reads the body, keeps 'pl' among what it doesn't know, and writes it back unchanged.
      final again = CircleManifest.fromJson(on.toJson());
      expect(again, isNotNull);
      expect(again!.extra['pl'], on.extra['pl']);
      expect(again.next(name: 'Table 2').pluginOn('recordcall'), isTrue, reason: 'an unrelated change keeps it');
      final off = again.next(extra: again.withPlugin('recordcall', on: false));
      expect(off.pluginOn('recordcall'), isFalse);
    });
  });

  group('Scribe', () {
    SaidLine l(String who, int s, int e, String text) => SaidLine(who: who, start: Duration(milliseconds: s), end: Duration(milliseconds: e), text: text);

    test('each voice\'s lines put in order of time, named, whatever track they came from', () {
      final merged = mergeLines([
        [l('Maya', 0, 1500, 'Right, where were we?'), l('Maya', 9000, 10000, 'Roll for it.')],
        [l('Sam', 1800, 4000, 'The bridge, the troll under it.'), l('Sam', 9000, 9500, 'Ugh.')],
      ]);
      expect([for (final x in merged) '${x.who}: ${x.text}'], ['Maya: Right, where were we?', 'Sam: The bridge, the troll under it.', 'Maya: Roll for it.', 'Sam: Ugh.']);
    });

    test('kept as words and as subtitles the player shows', () {
      final t = Transcript(lines: [l('Maya', 0, 1500, 'Right, where were we?'), l('Sam', 61800, 64000, 'The bridge.')], summary: 'They planned the bridge.');
      expect(t.text, 'They planned the bridge.\n\n[0:00] Maya: Right, where were we?\n[1:01] Sam: The bridge.');
      expect(t.srt, '1\n00:00:00,000 --> 00:00:01,500\nMaya: Right, where were we?\n\n2\n00:01:01,800 --> 00:01:04,000\nSam: The bridge.\n');
      final again = Transcript.fromJson(t.toJson())!;
      expect(again.text, t.text);
    });

    test('a plugin a circle can hold, off until added', () {
      const s = ScribePlugin();
      expect(s.onByDefault, isFalse);
      expect(s.scopes, contains(PluginScope.circle));
      expect(shippedPlugins.whereType<ScribePlugin>(), hasLength(1));
    });
  });

  // Matt, 2026-11-19: "add icons in the compose window or header depending on what makes sense for plugins like the
  // recording plugin and allow for changing settings like save location (expect saving to have at least one file space in
  // a circle we'll save to a folder in a given space within the circle)".
  group('where a circle\'s recordings go', () {
    Circle circle(List<CircleSpace> spaces, {Map<String, Object?> extra = const {}}) =>
        Circle(seed: '5' * 64, owner: '', manifest: CircleManifest(owner: '', name: 'Band', spaces: spaces, extra: extra));
    final chat = CircleSpace.make('Chat', kind: SpaceKind.text);
    final shared = CircleSpace.make('Shared', kind: SpaceKind.files, order: 1);
    final takes = CircleSpace.make('Takes', kind: SpaceKind.files, order: 2);

    test('until the circle chooses: its first Files space, in a folder named Recordings', () {
      final to = RecordCallPlugin.saveToIn(circle([chat, shared, takes]))!;
      expect(to.space.seed, shared.seed);
      expect(to.folder, 'Recordings');
      expect(to.channel.circle, '5' * 64, reason: 'the space as its circle has it');
    });

    test('the circle\'s choice of space and folder, kept with the plugin in its manifest', () {
      final c = circle([chat, shared, takes]);
      final chosen = circle([chat, shared, takes], extra: c.manifest.withPlugin('recordcall', on: true, choices: {'space': takes.seed, 'folder': 'Sessions/2026'}));
      final to = RecordCallPlugin.saveToIn(chosen)!;
      expect(to.space.seed, takes.seed);
      expect(to.folder, 'Sessions/2026');
      expect(chosen.manifest.pluginOn('recordcall'), isTrue, reason: 'choosing a place leaves the switch as it was');
    });

    test('a chosen space that is gone, or a folder that is no folder, falls back', () {
      final c = circle([chat, shared]);
      final to = RecordCallPlugin.saveToIn(circle([chat, shared], extra: c.manifest.withPlugin('recordcall', on: true, choices: {'space': 'gone', 'folder': '../..'})))!;
      expect(to.space.seed, shared.seed);
      expect(to.folder, 'Recordings');
    });

    test('with no Files space there is nowhere in the circle to save to', () {
      expect(RecordCallPlugin.saveToIn(circle([chat])), isNull);
    });

    test('Record and Stop are in the space\'s header only while this device is in its call', () {
      List<String> header(SpacePlace p) => [
            for (final f in const RecordCallPlugin().slots)
              if (f is ActionFill<SpacePlace>) ...[for (final a in f.build(p, PluginPrefs.none)) a.label],
          ];
      const space = SpacePlace(space: 's', spaceName: 'Lounge', circle: 'c');
      expect(header(space), isEmpty, reason: 'not in its call');
      expect(header(const SpacePlace(space: 's', spaceName: 'Notes', voice: false, inCall: true)), isEmpty, reason: 'no call in a texting space');
      if (CallRecorder.supported) {
        // With video where this device can take it (GMFB-42), which is what the one button then says.
        expect(header(const SpacePlace(space: 's', spaceName: 'Lounge', circle: 'c', inCall: true)), [CallRecorder.videoSupported ? 'Record voice and video' : 'Record this call']);
      }
    });
  });

  // GMFB-52 ("After a user says include me I expect them to show up in the mixer and their audio to be recorded
  // however I don't see them in the mixer or their audio in the all"): the recorder looked for each voice in the
  // streams the call's tiles draw, which hold pictures only, so nobody was ever tapped. It asks the media now
  // (SoundMedia), and follows a connection that is made again mid-call.
  group('whose voice is tapped (GMFB-52)', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('ghost/recorder');
    final calls = <MethodCall>[];
    late Directory dir;
    late _SoundsMedia media;
    late VoiceSession s;

    /// The taps asked of the native half, as "key track".
    List<String> adds() => [for (final c in calls) if (c.method == 'add') '${(c.arguments as Map)['key']} ${(c.arguments as Map)['track']}'];

    /// Lets what the recorder does after the session or the media changes run.
    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

    setUp(() {
      calls.clear();
      dir = Directory.systemTemp.createTempSync('gm-rec-');
      CallRecorder.folderForTest = dir;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async {
        calls.add(c);
        return c.method == 'stop' ? <String, int>{} : true;
      });
      media = _SoundsMedia();
      s = VoiceSession(channel: VoiceChannel.make('Lounge'), route: _NoRoute(), media: media, name: 'Matt')..joined = true;
      Voice.instance.session = s;
    });

    tearDown(() async {
      await CallRecorder.instance.stop();
      Voice.instance.session = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      CallRecorder.folderForTest = null;
      dir.deleteSync(recursive: true);
    });

    /// What [id] says of themselves now: whether their voice may be in the recording being made.
    void says(String id, {required bool yes}) {
      final r = CallRecorder.instance.recording!;
      s.members[id] = VoiceMember(id, name: id, notices: true, agreed: yes ? {r} : const {}, declined: yes ? const {} : {r});
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      s.notifyListeners();
    }

    test('someone who says yes after the recording began is tapped, and is in the mixer', () async {
      if (!CallRecorder.supported) return;
      s.members['bob'] = const VoiceMember('bob', name: 'bob', notices: true);
      media.sounds.value = {'bob': (track: 'mic-bob', link: 1)};
      expect(await CallRecorder.instance.start(), isNull);
      await settle();
      expect(adds(), isEmpty, reason: 'nobody has said yes');
      expect([for (final t in CallRecorder.instance.tracks) t.key], ['me']);

      says('bob', yes: true);
      await settle();
      expect(adds(), ['bob mic-bob']);
      expect([for (final t in CallRecorder.instance.tracks) (t.key, t.live)], [('me', true), ('bob', true)]);
      expect(CallRecorder.instance.recordedNames, hasLength(2));

      // And out again when they take it back.
      says('bob', yes: false);
      await settle();
      expect([for (final c in calls) if (c.method == 'remove') (c.arguments as Map)['key']], ['bob']);
      expect([for (final t in CallRecorder.instance.tracks) t.key], ['me']);
    });

    test('someone who said yes before their sound came is tapped when it comes', () async {
      if (!CallRecorder.supported) return;
      expect(await CallRecorder.instance.start(), isNull);
      says('bob', yes: true);
      await settle();
      expect(adds(), isEmpty, reason: 'no sound of theirs yet');
      media.sounds.value = {'bob': (track: 'mic-bob', link: 1)};
      await settle();
      expect(adds(), ['bob mic-bob']);
    });

    test('a connection made again is tapped anew, though their track has the same id', () async {
      if (!CallRecorder.supported) return;
      media.sounds.value = {'bob': (track: 'mic-bob', link: 1)};
      expect(await CallRecorder.instance.start(), isNull);
      says('bob', yes: true);
      await settle();
      expect(adds(), ['bob mic-bob']);

      // The connection breaks: they stay in the recording, with nothing to tap for now.
      media.sounds.value = const {};
      await settle();
      expect(adds(), ['bob mic-bob']);
      expect([for (final c in calls) if (c.method == 'remove') c], isEmpty, reason: 'still in the call, still a yes');
      expect([for (final t in CallRecorder.instance.tracks) t.key], ['me', 'bob']);

      // And is made again: the same microphone, so the same track id, on a new connection.
      media.sounds.value = {'bob': (track: 'mic-bob', link: 2)};
      await settle();
      expect(adds(), ['bob mic-bob', 'bob mic-bob'], reason: 'the new connection\'s track, into the same file');
      final paths = {for (final c in calls) if (c.method == 'add') (c.arguments as Map)['path']};
      expect(paths, hasLength(1));
    });
  });
}

class _NoRoute implements VoiceRoute {
  @override
  String get me => 'me-id';
  @override
  Future<List<String>> join(String room, String token) async => const [];
  @override
  void leave(String room) {}
  @override
  void send(String room, Uint8List bytes) {}
  @override
  void look(String room, String token) {}
  @override
  void unlook(String room) {}
  @override
  Stream<RoomEvent> get events => const Stream.empty();
  @override
  Stream<({String room, String from, Uint8List bytes})> get packets => const Stream.empty();
  @override
  Stream<({String room, List<String> members})> get looks => const Stream.empty();
}

/// WebRTC stood in for: the test says whose sound has come, on which track of which connection.
class _SoundsMedia implements VoiceMedia, SoundMedia {
  @override
  final ValueNotifier<Map<String, double>> levels = ValueNotifier(const {});
  @override
  final ValueNotifier<Map<String, VoiceSound>> sounds = ValueNotifier(const {});
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
  VoicePeer peer(String id, {required void Function(Map<String, dynamic> candidate) onCandidate}) => throw UnimplementedError();
  @override
  void setPeerVolume(String id, double volume) {}
  @override
  void setPeerMuted(String id, bool muted) {}
}
