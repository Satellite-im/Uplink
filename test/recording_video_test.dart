import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/files/files_store.dart' show FilesInfo;
import 'package:ghost_messaging/net/hub_carrier.dart' show RoomEvent;
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/record_call.dart';
import 'package:ghost_messaging/voice/channels.dart';
import 'package:ghost_messaging/voice/mp4_names.dart';
import 'package:ghost_messaging/voice/recorder.dart';
import 'package:ghost_messaging/voice/recording_video.dart';
import 'package:ghost_messaging/voice/voice.dart';

/// A recording's picture (GMFB-42: "Extend the Record call plugin so a recording can also capture the webcams and
/// screenshares in the call, not just the audio tracks"; Matt, 2026-11-23: "One composed video"): who may be drawn,
/// where each tile goes, the choice at the start and which devices have it, and the file's tracks afterwards
/// (lib/voice/recording_video.dart, lib/voice/recorder.dart, lib/plugins/record_call.dart).

VideoFace _cam(String key, {bool on = true}) => VideoFace(key: key, name: key, track: on ? 'cam-$key' : null, mark: on ? '1' : '');
VideoFace _screen(String key) => VideoFace(key: key, name: key, track: 'screen-$key', mark: '1', screen: true);

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

/// A track as a writer makes one: a header (version 0, enabled, in no group) and a handler of [kind].
Uint8List _trak(int id, String kind) {
  final tkhd = ByteData(84)
    ..setUint32(0, 0x00000007)
    ..setUint32(12, id);
  final hdlr = BytesBuilder()
    ..add(Uint8List(8))
    ..add(latin1.encode(kind))
    ..add(Uint8List(12))
    ..add(Uint8List.fromList([...latin1.encode('Core Media'), 0]));
  return _box('trak', [
    _box('tkhd', [tkhd.buffer.asUint8List()]),
    _box('mdia', [_box('hdlr', [hdlr.toBytes()])]),
  ]);
}

void main() {
  group('who is drawn', () {
    List<VideoFace> faces(List<VoiceMember> members, {({String track, bool screen})? own, Map<String, VoiceSound> pictures = const {}}) =>
        RecordingVideo.faces(recording: 'rec', myName: 'Matt', members: members, nameOf: (id) => 'Name of $id', own: own, pictures: pictures);
    const pictures = {'a': (track: 'cam-a', link: 7)};

    test('this device\'s person first: a name while their camera is off, their camera or screen while it is sent', () {
      expect(faces(const []).single.key, 'me');
      expect(faces(const []).single.track, isNull);
      final cam = faces(const [], own: (track: 'my-cam', screen: false)).single;
      expect((cam.track, cam.screen, cam.name), ('my-cam', false, 'Matt'));
      expect(faces(const [], own: (track: 'my-screen', screen: true)).single.screen, isTrue);
    });

    test('a yes to voice and video, with a camera on: their picture', () {
      final f = faces(const [VoiceMember('a', notices: true, video: true, agreed: {'rec'}, pictured: {'rec'})], pictures: pictures).last;
      expect((f.key, f.name, f.track, f.mark, f.screen), ('a', 'Name of a', 'cam-a', '7', false));
    });

    test('a yes to the voice alone (an older build, or a recording that asked only that): a tile with their name, never their picture', () {
      final f = faces(const [VoiceMember('a', notices: true, video: true, agreed: {'rec'})], pictures: pictures).last;
      expect(f.key, 'a');
      expect(f.track, isNull, reason: 'their camera is on and its track is here, and it is still not drawn');
      // Nor their screen.
      final s = faces(const [VoiceMember('a', notices: true, video: true, screen: true, agreed: {'rec'})], pictures: pictures).last;
      expect((s.track, s.screen), (null, false));
      // Nor with a yes to the picture of some other recording.
      expect(faces(const [VoiceMember('a', notices: true, video: true, agreed: {'rec'}, pictured: {'other'})], pictures: pictures).last.track, isNull);
    });

    test('a no, or no answer yet: no tile at all', () {
      expect(faces(const [VoiceMember('a', notices: true, video: true)], pictures: pictures).map((f) => f.key), ['me']);
      expect(faces(const [VoiceMember('a', notices: true, video: true, declined: {'rec'})], pictures: pictures).map((f) => f.key), ['me']);
      // Taken back after a yes to both: what was said beside the no counts for nothing.
      expect(faces(const [VoiceMember('a', notices: true, video: true, agreed: {'rec'}, declined: {'rec'}, pictured: {'rec'})], pictures: pictures).map((f) => f.key), ['me']);
    });

    test('a yes to both with the camera off, or before their picture has come: their name', () {
      expect(faces(const [VoiceMember('a', notices: true, agreed: {'rec'}, pictured: {'rec'})], pictures: pictures).last.track, isNull, reason: 'a connection carries a picture track from its start, with nothing on it');
      expect(faces(const [VoiceMember('a', notices: true, video: true, agreed: {'rec'}, pictured: {'rec'})]).last.track, isNull);
    });

    test('a shared screen is said to be one, with their yes', () {
      final f = faces(const [VoiceMember('a', notices: true, video: true, screen: true, agreed: {'rec'}, pictured: {'rec'})], pictures: pictures).last;
      expect((f.track, f.screen), ('cam-a', true));
    });
  });

  group('where each tile goes', () {
    const all = ui.Rect.fromLTWH(0, 0, 1280, 720);
    void sound(VideoLayout l) {
      for (final t in l.tiles) {
        expect(all.contains(t.rect.topLeft) && t.rect.right <= 1280 && t.rect.bottom <= 720, isTrue, reason: '${t.key} is in the picture');
        expect(t.rect.left == t.rect.left.roundToDouble() && t.rect.width == t.rect.width.roundToDouble(), isTrue, reason: 'whole pixels');
        expect(t.picture.left >= t.rect.left && t.picture.right <= t.rect.right && t.picture.top >= t.rect.top && t.picture.bottom <= t.rect.bottom, isTrue);
        for (final o in l.tiles) {
          if (!identical(o, t)) expect(t.rect.overlaps(o.rect), isFalse, reason: '${t.key} and ${o.key} do not overlap');
        }
      }
    }

    test('cameras in a grid, as near square as their number allows, every tile the same size', () {
      for (final (n, across, down) in [(1, 1, 1), (2, 2, 1), (3, 2, 2), (4, 2, 2), (5, 3, 2), (6, 3, 2), (7, 3, 3), (9, 3, 3), (10, 4, 3), (16, 4, 4)]) {
        final l = RecordingVideo.layout([for (var i = 0; i < n; i++) _cam('p$i')]);
        expect(l.tiles, hasLength(n));
        sound(l);
        expect({for (final t in l.tiles) t.rect.top}.length, down, reason: '$n people in $down rows');
        expect(l.tiles.where((t) => t.rect.top == l.tiles.first.rect.top).length, across, reason: '$n people, $across across');
        expect({for (final t in l.tiles) (t.rect.width / 2).round()}.length, 1);
        expect(l.tiles.every((t) => !t.stage && !t.contain), isTrue, reason: 'a camera fills its tile');
        expect([for (final t in l.tiles) t.key], [for (var i = 0; i < n; i++) 'p$i'], reason: 'in the order they are given');
      }
    });

    test('a row that is not full stands in the middle', () {
      final l = RecordingVideo.layout([for (var i = 0; i < 3; i++) _cam('p$i')]);
      final last = l.tiles.last.rect;
      expect((last.left - (1280 - last.right)).abs() <= 1, isTrue);
    });

    test('each tile keeps a strip for its name under its picture', () {
      final l = RecordingVideo.layout([_cam('a'), _cam('b', on: false)]);
      for (final t in l.tiles) {
        expect(t.rect.bottom - t.picture.bottom, RecordingVideo.strip);
      }
      expect(l.tiles.last.track, isNull, reason: 'a tile with no picture is still a tile: their name and initial');
    });

    test('a shared screen is large on the left, drawn whole, and everyone else small in a column beside it', () {
      final l = RecordingVideo.layout([_cam('me'), _screen('a'), _cam('b'), _cam('c', on: false)]);
      sound(l);
      final stage = l.tiles.singleWhere((t) => t.stage);
      expect(l.tiles.first.key, 'a', reason: 'the screen first');
      expect(stage.contain, isTrue, reason: 'words on a screen are not cut off');
      expect(stage.rect.width > 960 && stage.rect.height > 680, isTrue);
      final small = l.tiles.where((t) => !t.stage).toList();
      expect([for (final t in small) t.key], ['me', 'b', 'c']);
      for (final t in small) {
        expect(t.rect.left >= stage.rect.right, isTrue);
        expect(t.rect.width, RecordingVideo.side);
        expect(t.contain, isFalse);
      }
      expect({for (final t in small) t.rect.left}.length, 1, reason: 'one column');
    });

    test('a screen shared alone has the whole picture; a second screen is small, and whole', () {
      final alone = RecordingVideo.layout([_screen('me')]);
      expect(alone.tiles.single.stage, isTrue);
      expect(alone.tiles.single.rect.width, 1280 - RecordingVideo.gap * 2);
      final two = RecordingVideo.layout([_screen('me'), _screen('a')]);
      expect([for (final t in two.tiles) (t.key, t.stage, t.contain)], [('me', true, true), ('a', false, true)]);
    });

    test('many beside a screen still fit: the column\'s tiles get lower, none leaves the picture', () {
      final l = RecordingVideo.layout([_screen('s'), for (var i = 0; i < 12; i++) _cam('p$i')]);
      sound(l);
      expect(l.tiles, hasLength(13));
    });

    test('someone comes, leaves, turns a camera off, or a connection is made again: the words of the layout change', () {
      final base = RecordingVideo.layout([_cam('me'), _cam('a')]).signature;
      expect(RecordingVideo.layout([_cam('me'), _cam('a')]).signature, base, reason: 'the same call, the same words: nothing is sent again');
      expect(RecordingVideo.layout([_cam('me'), _cam('a'), _cam('b')]).signature, isNot(base));
      expect(RecordingVideo.layout([_cam('me')]).signature, isNot(base));
      expect(RecordingVideo.layout([_cam('me'), _cam('a', on: false)]).signature, isNot(base));
      expect(RecordingVideo.layout([_cam('me'), const VideoFace(key: 'a', name: 'a', track: 'cam-a', mark: '2')]).signature, isNot(base));
      expect(RecordingVideo.layout([_cam('me'), const VideoFace(key: 'a', name: 'Ada', track: 'cam-a', mark: '1')]).signature, isNot(base));
    });

    test('the native half is handed only pictures, each where its tile\'s picture goes', () {
      final l = RecordingVideo.layout([_cam('me'), _cam('a', on: false), _screen('b')]);
      final native = l.toNative();
      expect([for (final t in native) t['track']], ['screen-b', 'cam-me']);
      final stage = l.tiles.first;
      expect(native.first, {'track': 'screen-b', 'x': stage.picture.left.round(), 'y': stage.picture.top.round(), 'w': stage.picture.width.round(), 'h': stage.picture.height.round(), 'contain': true});
    });

    test('the plate is the whole picture, with each tile painted on it', () async {
      final l = RecordingVideo.layout([_cam('me'), _cam('a', on: false)]);
      final plate = await RecordingVideo.plate(l);
      expect(plate.length, 1280 * 720 * 4);
      List<int> at(double x, double y) => plate.sublist((y.round() * 1280 + x.round()) * 4, (y.round() * 1280 + x.round()) * 4 + 4);
      expect(at(1, 1)[3], 255, reason: 'nothing shows through');
      final tile = l.tiles.last;
      expect(at(tile.rect.left + 4, tile.rect.top + 4), isNot(at(1, 1)), reason: 'a tile is not the colour between tiles');
      expect(at(tile.picture.center.dx - 40, tile.picture.center.dy), isNot(at(tile.rect.left + 4, tile.rect.top + 4)), reason: 'the disc their initial is on');
    });

    test('the initial is the first letter of their name', () {
      expect(RecordingVideo.initial(' maya '), 'M');
      expect(RecordingVideo.initial('Élodie'), 'É');
      expect(RecordingVideo.initial(''), '?');
    });
  });

  group('the choice at the start, and which devices have it', () {
    test('video is a Mac\'s and a Windows PC\'s: not a phone\'s, a browser\'s or Linux\'s', () {
      expect(RecordingVideo.supportedOn(web: false, macOS: true), isTrue);
      expect(RecordingVideo.supportedOn(web: false, macOS: false), isFalse);
      expect(RecordingVideo.supportedOn(web: true, macOS: true), isFalse);
      // A Windows PC too (Matt, 2026-11-26: "Build Windows too"); never in a browser.
      expect(RecordingVideo.supportedOn(web: false, macOS: false, windows: true), isTrue);
      expect(RecordingVideo.supportedOn(web: true, macOS: false, windows: true), isFalse);
      expect(CallRecorder.videoSupported, !kIsWeb && Platform.isMacOS);
    });

    test('where the device can: with video first, or the voices alone; elsewhere the one way there was', () {
      final mac = RecordCallPlugin.startChoices(video: true);
      expect([for (final c in mac) (c.label, c.video)], [('Record voice and video', true), ('Record voice only', false)]);
      final other = RecordCallPlugin.startChoices(video: false);
      expect([for (final c in other) (c.label, c.video)], [('Record this call', false)]);
    });

    test('the call\'s menu offers each way; the space\'s header the first', () {
      Voice.instance.session = null;
      final header = [
        for (final f in const RecordCallPlugin().slots)
          if (f is ActionFill<SpacePlace>) ...[for (final a in f.build(const SpacePlace(space: 's', spaceName: 'Lounge', circle: 'c', inCall: true), PluginPrefs.none)) a.label],
      ];
      if (!CallRecorder.supported) return;
      expect(header, [RecordCallPlugin.startChoices(video: CallRecorder.videoSupported).first.label]);
    });

    test('the cards in the space\'s chat say when it is with video', () {
      const p = RecordCallPlugin();
      expect(p.card(const PluginChatNote('recordcall', 'started', {'by': 'Maya', 'video': '1'}), mine: false)!.title, 'Maya started recording, with video');
      expect(p.card(const PluginChatNote('recordcall', 'started', {'by': 'Maya'}), mine: false)!.title, 'Maya started recording');
      final facts = p.card(const PluginChatNote('recordcall', 'stopped', {'by': 'Maya', 'seconds': '90', 'voices': '2', 'video': '1'}), mine: false)!.facts;
      expect([for (final f in facts) f.$2], contains('MP4, video and a track each'));
    });
  });

  group('a recording with video being made', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('ghost/recorder');
    final calls = <MethodCall>[];
    late Directory dir;
    late _PicturesMedia media;
    late VoiceSession s;

    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 60));
    List<String> methods() => [for (final c in calls) c.method];

    /// The tracks the native half was last told to draw.
    List<String> drawn() {
      final last = calls.lastWhere((c) => c.method == 'video.layout');
      return [for (final t in (last.arguments as Map)['tiles'] as List) '${(t as Map)['track']}'];
    }

    setUp(() {
      calls.clear();
      dir = Directory.systemTemp.createTempSync('gm-recv-');
      CallRecorder.folderForTest = dir;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async {
        calls.add(c);
        return switch (c.method) {
          'stop' => <String, int>{},
          'video.layout' => <String>[],
          'video.stop' => <String, int>{'frames': 0},
          _ => true,
        };
      });
      media = _PicturesMedia();
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

    void says(VoiceMember m) {
      s.members[m.id] = m;
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      s.notifyListeners();
    }

    test('started without the choice it is the voices alone, as it always was', () async {
      if (!CallRecorder.supported) return;
      expect(await CallRecorder.instance.start(), isNull);
      await settle();
      expect(CallRecorder.instance.recordingVideo, isFalse);
      expect(s.recordingVideo, isFalse);
      expect(methods().where((m) => m.startsWith('video.')), isEmpty);
      await CallRecorder.instance.stop();
      expect(methods().where((m) => m.startsWith('video.')), isEmpty);
    });

    test('with video: everyone is asked about both, and only a yes to both is drawn', () async {
      if (!CallRecorder.videoSupported) return;
      media.own = (track: 'my-cam', screen: false);
      media.pictures = {'old': (track: 'cam-old', link: 1), 'new': (track: 'cam-new', link: 1)};
      expect(await CallRecorder.instance.start(video: true), isNull);
      final rec = CallRecorder.instance.recording!;
      await settle();
      expect(CallRecorder.instance.recordingVideo, isTrue);
      expect(s.recordingVideo, isTrue, reason: 'said to the call, so the others are asked "voice and video"');
      expect(s.pictured, {rec}, reason: 'its maker is in their own picture');
      expect(methods().indexOf('video.start') > methods().indexOf('start'), isTrue);
      final asked = calls.firstWhere((c) => c.method == 'video.start').arguments as Map;
      expect((asked['width'], asked['height'], asked['fps'], asked['bitrate']), (1280, 720, 15, 1600000));
      expect(drawn(), ['my-cam']);
      final plate = (calls.lastWhere((c) => c.method == 'video.layout').arguments as Map)['plate'] as Uint8List;
      expect(plate.length, 1280 * 720 * 4);

      // A build from before this says yes to the voice: heard, and named on a tile, never seen.
      says(VoiceMember('old', name: 'Old', notices: true, video: true, agreed: {rec}));
      await settle();
      expect(drawn(), ['my-cam']);
      expect([for (final c in calls) if (c.method == 'add') (c.arguments as Map)['key']], isEmpty, reason: 'no sound of theirs has come in this test');

      // A yes to voice and video, camera on: drawn.
      says(VoiceMember('new', name: 'New', notices: true, video: true, agreed: {rec}, pictured: {rec}));
      await settle();
      expect(drawn(), unorderedEquals(['my-cam', 'cam-new']));

      // Their camera turned off mid-recording: their name in its place.
      says(VoiceMember('new', name: 'New', notices: true, agreed: {rec}, pictured: {rec}));
      await settle();
      expect(drawn(), ['my-cam']);

      // On again, then the yes taken back: gone at once.
      says(VoiceMember('new', name: 'New', notices: true, video: true, agreed: {rec}, pictured: {rec}));
      await settle();
      expect(drawn(), unorderedEquals(['my-cam', 'cam-new']));
      says(VoiceMember('new', name: 'New', notices: true, video: true, declined: {rec}));
      await settle();
      expect(drawn(), ['my-cam']);

      // This device shares its screen: it is what is sent, and it is drawn whole.
      media.own = (track: 'my-screen', screen: true);
      media.pictureChanges.value++;
      await settle();
      expect(drawn(), ['my-screen']);
      final tile = ((calls.lastWhere((c) => c.method == 'video.layout').arguments as Map)['tiles'] as List).single as Map;
      expect(tile['contain'], isTrue);

      final before = calls.where((c) => c.method == 'video.layout').length;
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      s.notifyListeners();
      await settle();
      expect(calls.where((c) => c.method == 'video.layout').length, before, reason: 'nothing changed, so nothing is painted or sent again');

      await CallRecorder.instance.stop();
      expect(methods().indexOf('video.stop') < methods().lastIndexOf('stop'), isTrue, reason: 'the picture\'s file is closed before the voices\'');
      expect(s.recordingVideo, isFalse);
    });

    test('a picture said before the native half holds its track is said again', () async {
      if (!CallRecorder.videoSupported) return;
      var misses = 1;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async {
        calls.add(c);
        if (c.method == 'video.layout') return misses-- > 0 ? <String>['my-cam'] : <String>[];
        return c.method == 'stop' || c.method == 'video.stop' ? <String, int>{} : true;
      });
      media.own = (track: 'my-cam', screen: false);
      expect(await CallRecorder.instance.start(video: true), isNull);
      await settle();
      expect(calls.where((c) => c.method == 'video.layout'), hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(calls.where((c) => c.method == 'video.layout'), hasLength(2));
    });

    test('where the picture\'s file can\'t be begun the recording goes on as the voices alone, and asks for no more', () async {
      if (!CallRecorder.videoSupported) return;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async {
        calls.add(c);
        if (c.method == 'video.start') return false;
        return c.method == 'stop' ? <String, int>{} : true;
      });
      expect(await CallRecorder.instance.start(video: true), isNull);
      await settle();
      expect(CallRecorder.instance.recordingVideo, isFalse);
      expect(s.recordingVideo, isFalse, reason: 'nobody is asked for a picture that is not being taken');
      expect(methods(), isNot(contains('video.layout')));
    });
  });

  group('the file afterwards', () {
    test('the video track is left enabled and in no group when the voices are named; the mix is still the one voice enabled', () {
      final moov = _box('moov', [_trak(1, 'soun'), _trak(2, 'soun'), _trak(3, 'vide')]);
      final made = Mp4Names.rename(moov, ['Everyone', 'Maya']);
      final tracks = Mp4Names.read(made);
      expect([for (final t in tracks) (t.name, t.kind)], [('Everyone', 'soun'), ('Maya', 'soun'), ('Core Media', 'vide')], reason: 'a track past the names keeps its own');
      // Each track's header: its flags at byte 11 of the box, its alternate group at byte 42.
      final heads = <(bool, int)>[];
      var at = 8;
      final d = ByteData.sublistView(made);
      while (at + 8 <= made.length) {
        final size = d.getUint32(at);
        final tkhd = at + 8;
        heads.add((made[tkhd + 11] & 1 == 1, d.getUint16(tkhd + 8 + 4 + 20 + 8 + 2)));
        at += size;
      }
      expect(heads, [(true, 1), (false, 1), (true, 0)]);
    });

    test('a kept recording says it has video, and one from before reads as it did', () {
      final r = Recording(id: 'rec1', path: '/x/rec1.mp4', space: 'Lounge', at: DateTime(2026, 11, 23), seconds: 60, people: const ['Matt'], video: true);
      expect(Recording.fromJson(jsonDecode(jsonEncode(r.toJson())))!.video, isTrue);
      expect(Recording.fromJson({'id': 'rec0', 'path': '/x/rec0.mp4', 'at': 1})!.video, isFalse);
      expect(Recording(id: 'a', path: 'p', space: '', at: DateTime(2026), seconds: 1, people: const []).toJson().containsKey('video'), isFalse);
    });

    test('too big for the circle\'s Files space is said in words as the recording stops', () {
      const half = 500 * 1000 * 1000;
      expect(RecordCallPlugin.tooBigFor(null, half, 'Files'), isNull, reason: 'nothing known of the space yet: the upload itself says');
      expect(RecordCallPlugin.tooBigFor(const FilesInfo(maxFile: 50000000000, quota: 100000000000, used: 0), half, 'Files'), isNull);
      expect(RecordCallPlugin.tooBigFor(const FilesInfo(maxFile: 100 * 1000 * 1000), half, 'Files'), allOf(startsWith('Kept on this device'), contains('too big for Files')));
      expect(RecordCallPlugin.tooBigFor(const FilesInfo(maxFile: 50000000000, quota: 1000 * 1000 * 1000, used: 800 * 1000 * 1000), half, 'Files'), allOf(startsWith('Kept on this device'), contains('no room left')));
      expect(RecordCallPlugin.tooBigFor(const FilesInfo(maxFile: 1), 0, 'Files'), isNull);
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

/// WebRTC stood in for: the test says which pictures there are.
class _PicturesMedia implements VoiceMedia, SoundMedia, PictureMedia {
  @override
  final ValueNotifier<Map<String, double>> levels = ValueNotifier(const {});
  @override
  final ValueNotifier<Map<String, VoiceSound>> sounds = ValueNotifier(const {});
  @override
  Map<String, VoiceSound> pictures = const {};
  ({String track, bool screen})? own;
  @override
  ({String track, bool screen})? get ownPicture => own;
  @override
  final ValueNotifier<int> pictureChanges = ValueNotifier(0);
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
