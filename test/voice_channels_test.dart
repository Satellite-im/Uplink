import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStream;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/voice/channels.dart';
import 'package:ghost_messaging/voice/rtc.dart';
import 'package:ghost_messaging/voice/voice.dart';
import 'package:ghost_messaging/voice/watch_together.dart';
import 'package:ghost_messaging/files/files_model.dart';
import 'package:ghost_messaging/ui/video_engine.dart';
import 'package:flutter/widgets.dart' show Widget, SizedBox;

/// Voice and video channels (lib/voice/voice.dart). Matt, 2026-11-14: "jump in audio chats like discord has always
/// open voice channels that you can jump in and out at any time and you can see who's connected and also toggle video
/// on and off ... please make sure we stream at lossless quality".
///
/// A hub stood in for (rooms: join, leave, a packet to everyone else, who came and went) and WebRTC stood in for (each
/// connection says what it was asked to make and take), so what goes between the members can be watched.
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

/// Media that can share a screen (ScreenMedia), saying what it was asked; [refuse] stands for the person saying no to
/// the system's question.
class _Screens extends _Media implements ScreenMedia {
  bool refuse = false;
  String? sharing;
  void Function()? ended;
  @override
  bool get screenSupported => true;
  @override
  Future<List<ScreenSource>> screenSources() async => const [ScreenSource(id: 'screen:0', name: 'Entire screen', window: false)];
  @override
  Future<bool> setScreen(bool on, {String? source, void Function()? onEnded}) async {
    if (on && refuse) return false;
    sharing = on ? (source ?? 'phone') : null;
    ended = onEnded;
    return true;
  }

  @override
  final ValueNotifier<MediaStream?> localScreen = ValueNotifier(null);

  /// The system stopped it (its own Stop sharing, the window closed).
  void systemStop() {
    sharing = null;
    ended?.call();
  }
}

/// Media whose connections can fail, and be made through the relay alone (FallbackMedia).
class _Fallback extends _Media implements FallbackMedia {
  _Fallback({this.hasRelay = true});
  @override
  final bool hasRelay;
  final Map<String, void Function()> fail = {};
  final Map<String, bool> relayOnlyOf = {};
  @override
  VoicePeer peerWith(String id, {required void Function(Map<String, dynamic> candidate) onCandidate, required void Function() onFailed, bool relayOnly = false}) {
    log.add('made $id${relayOnly ? ' (relay only)' : ''}');
    fail[id] = onFailed;
    relayOnlyOf[id] = relayOnly;
    return _Peer(this, id, onCandidate);
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// A player that only keeps what it is told, for watching together.
class _Engine extends VideoEngine {
  final said = <String>[];
  @override
  Future<void> open(String path) async => value = value.copyWith(ready: true, duration: const Duration(minutes: 90));
  @override
  Future<void> play() async {
    said.add('play');
    value = value.copyWith(playing: true);
  }

  @override
  Future<void> pause() async {
    said.add('pause');
    value = value.copyWith(playing: false);
  }

  @override
  Future<void> seek(Duration to) async {
    said.add('seek ${to.inSeconds}');
    value = value.copyWith(position: to);
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Widget view() => const SizedBox();
  @override
  Future<void> release() async {}
}

void main() {
  test('watching together: the file and where it is go to the call, and a player that is out of step is moved', () async {
    // Matt, 2026-11-19: "watch together".
    final hub = _Hub();
    final c = VoiceChannel.make('Film night');
    final maya = VoiceSession(channel: c, route: _Route(hub, 'maya-id'), media: _Media(), name: 'Maya');
    final sam = VoiceSession(channel: c, route: _Route(hub, 'sam-id'), media: _Media(), name: 'Sam');
    await maya.join();
    await sam.join();
    await _settle();
    final file = SpaceFile.fromJson({'id': '0123456789abcdef0123456789abcdef', 'n': 'Film.mkv', 'z': 1000, 'm': 'video/x-matroska', 'k': base64Encode(List.filled(32, 7)), 'p': base64Encode(List.filled(8, 1)), 'u': 'Maya', 'at': 1}, by: 'maya-id')!;
    final w = WatchTogether.instance..followSession(sam);
    final engine = _Engine();
    await engine.open('x');
    w.attach(engine);
    expect(engine.said, ['play'], reason: 'nothing to follow yet: it plays from the start');

    maya.sayWatch(Watching(file: file, space: c.seed, by: 'me', position: const Duration(minutes: 20), playing: true, at: DateTime.now()).toWire());
    await _settle();
    expect(w.watching!.file.name, 'Film.mkv');
    expect(w.watching!.by, 'maya-id');
    expect(engine.said.last, 'seek 1200', reason: 'twenty minutes in, where Maya is');

    engine.said.clear();
    maya.sayWatch(Watching(file: file, space: c.seed, by: 'me', position: const Duration(minutes: 20, seconds: 1), playing: false, at: DateTime.now()).toWire());
    await _settle();
    expect(engine.said, ['pause'], reason: 'a second away is left alone; paused is paused');

    // Sam moves it: Maya's side hears where.
    final heard = <String>[];
    maya.onWatch = (from, m) => heard.add('$from ${m['p']} ${m['g']}');
    w.user(playing: true, position: const Duration(minutes: 30));
    await _settle();
    expect(heard, ['sam-id 1800000 true']);

    maya.sayWatch({'e': true});
    await _settle();
    expect(w.watching, isNull);
    w.detach(engine);
    w.followSession(null);
    await maya.leave();
    await sam.leave();
  });

  test('captions: who wants them is said, and each line of words goes to everyone in the call', () async {
    // Matt, 2026-11-19: "Live captions".
    final hub = _Hub();
    final c = VoiceChannel.make('Study hall');
    final maya = VoiceSession(channel: c, route: _Route(hub, 'maya-id'), media: _Media(), name: 'Maya');
    final sam = VoiceSession(channel: c, route: _Route(hub, 'sam-id'), media: _Media(), name: 'Sam');
    await maya.join();
    await sam.join();
    await _settle();
    expect(maya.anyoneWantsCaptions, isFalse);

    sam.setWantsCaptions(true);
    await _settle();
    expect(maya.members['sam-id']!.captions, isTrue);
    expect(maya.anyoneWantsCaptions, isTrue, reason: 'Maya\'s device writes out her voice for Sam');

    final heard = <String>[];
    sam.onCaption = (from, words, done) => heard.add('$from $words $done');
    maya.sayCaption('the troll is', done: false);
    maya.sayCaption('the troll is under the bridge', done: true);
    await _settle();
    expect(heard, ['maya-id the troll is false', 'maya-id the troll is under the bridge true']);

    sam.setWantsCaptions(false);
    await _settle();
    expect(maya.anyoneWantsCaptions, isFalse);
    await maya.leave();
    await sam.leave();
  });

  test('a recording is told to everyone in the call, and a voice is in it only once its own device says yes', () async {
    // Matt, 2026-11-19: "a "record call" plugin where it records the call to an MP4 with multiple named audio tracks".
    final hub = _Hub();
    final c = VoiceChannel.make('Session zero');
    final maya = VoiceSession(channel: c, route: _Route(hub, 'maya-id'), media: _Media(), name: 'Maya');
    final sam = VoiceSession(channel: c, route: _Route(hub, 'sam-id'), media: _Media(), name: 'Sam');
    await maya.join();
    await sam.join();
    await _settle();
    expect(maya.members['sam-id']!.notices, isTrue, reason: 'this build says it shows recordings and asks');
    expect(sam.recordingsByOthers, isEmpty);

    maya.setRecording('rec1');
    maya.answerRecording('rec1', true);
    await _settle();
    expect(sam.members['maya-id']!.recording, 'rec1');
    expect(sam.recordingsByOthers, {'rec1': 'maya-id'});
    expect(sam.unanswered, ['rec1'], reason: 'asked, and not in it until answered');
    expect(maya.members['sam-id']!.agreed, isEmpty);

    sam.answerRecording('rec1', true);
    await _settle();
    expect(maya.members['sam-id']!.agreed, {'rec1'});
    expect(sam.unanswered, isEmpty);

    sam.answerRecording('rec1', false);
    await _settle();
    expect(maya.members['sam-id']!.agreed, isEmpty, reason: 'taking it back takes the voice out');
    expect(maya.members['sam-id']!.declined, {'rec1'});

    maya.setRecording(null);
    await _settle();
    expect(sam.recordingsByOthers, isEmpty);
    await maya.leave();
    await sam.leave();
  });

  test('a recording that takes pictures says so, and a picture is in it only where the yes was to voice and video (GMFB-42)', () async {
    final hub = _Hub();
    final c = VoiceChannel.make('Session zero');
    final maya = VoiceSession(channel: c, route: _Route(hub, 'maya-id'), media: _Media(), name: 'Maya');
    final sam = VoiceSession(channel: c, route: _Route(hub, 'sam-id'), media: _Media(), name: 'Sam');
    await maya.join();
    await sam.join();
    await _settle();

    // Sound only, as every recording was before: a yes is to the voice, and no picture follows from it.
    maya.setRecording('rec1');
    await _settle();
    expect(sam.members['maya-id']!.recordsVideo, isFalse);
    expect(sam.takesVideo('rec1'), isFalse);
    sam.answerRecording('rec1', true);
    await _settle();
    expect(maya.members['sam-id']!.agreed, {'rec1'});
    expect(maya.members['sam-id']!.pictured, isEmpty);
    expect(maya.members['sam-id']!.picturedIn('rec1'), isFalse);

    // With pictures: said beside the recording's id, and the yes then covers both.
    maya.setRecording('rec2', video: true);
    maya.answerRecording('rec2', true);
    await _settle();
    expect(maya.pictured, {'rec2'}, reason: 'its maker is in their own picture');
    expect(sam.members['maya-id']!.recordsVideo, isTrue);
    expect(sam.takesVideo('rec2'), isTrue);
    expect(sam.unanswered, ['rec2']);
    expect(maya.members['sam-id']!.picturedIn('rec2'), isFalse, reason: 'not until answered; the yes to rec1 is not one to rec2');
    sam.answerRecording('rec2', true);
    await _settle();
    expect(maya.members['sam-id']!.picturedIn('rec2'), isTrue);

    // Taken back: voice and picture both go.
    sam.answerRecording('rec2', false);
    await _settle();
    expect(maya.members['sam-id']!.pictured, isEmpty);
    expect(maya.members['sam-id']!.picturedIn('rec2'), isFalse);

    // A build from before this says yes to the voice alone ('ry' with no 'rp'): heard, never seen.
    expect(const VoiceMember('old', notices: true, agreed: {'rec2'}).picturedIn('rec2'), isFalse);
    // And a picture never outlasts a no, whatever is said beside it.
    expect(const VoiceMember('odd', notices: true, agreed: {'rec2'}, declined: {'rec2'}, pictured: {'rec2'}).picturedIn('rec2'), isFalse);

    maya.setRecording(null);
    await _settle();
    expect(maya.recordingVideo, isFalse);
    expect(sam.takesVideo('rec2'), isFalse);
    await maya.leave();
    await sam.leave();
  });

  test('a channel is made from its seed: the same room, token and key for every member; a group\'s from its id', () {
    final a = VoiceChannel.ofGroup('00112233445566778899aabbccddeeff', 'Climbing');
    final b = VoiceChannel.ofGroup('00112233445566778899aabbccddeeff', 'Climbing crew');
    expect(a.room, b.room);
    expect(a.token, b.token);
    expect(a.key, b.key);
    expect(a.room.length, 32);
    expect(a.token.length, 64);
    expect(VoiceChannel.ofGroup('ffeeddccbbaa99887766554433221100', 'x').room, isNot(a.room));
    final own = VoiceChannel.make('Hangout');
    expect(VoiceChannel.fromJson(own.toJson())!.room, own.room);
    expect(VoiceChannel.make('Hangout').room, isNot(own.room), reason: 'a new seed each time');
  });

  test('Opus is asked for at its highest: 510 kb/s, stereo, full band, constant, no silence cut', () {
    const sdp = 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111 63\r\na=rtpmap:111 opus/48000/2\r\na=fmtp:111 minptime=10;useinbandfec=1\r\na=rtpmap:63 red/48000/2\r\n';
    final out = highestOpus(sdp);
    final fmtp = out.split('\r\n').firstWhere((l) => l.startsWith('a=fmtp:111'));
    for (final want in ['maxaveragebitrate=510000', 'stereo=1', 'sprop-stereo=1', 'maxplaybackrate=48000', 'cbr=1', 'usedtx=0', 'useinbandfec=1']) {
      expect(fmtp, contains(want));
    }
    expect(out, contains('a=rtpmap:63 red/48000/2'), reason: 'everything else left as it was');
    // Where Opus has no fmtp line, one is added.
    expect(highestOpus('m=audio 9 RTP 111\r\na=rtpmap:111 opus/48000/2\r\n'), contains('a=fmtp:111 '));
  });

  test('hopping in and out: whoever comes offers, those there answer, names and state go sealed, and leaving closes', () async {
    final hub = _Hub();
    final c = VoiceChannel.make('Hangout');
    final mayaMedia = _Media(), samMedia = _Media();
    final maya = VoiceSession(channel: c, route: _Route(hub, 'maya-id'), media: mayaMedia, name: 'Maya');
    final sam = VoiceSession(channel: c, route: _Route(hub, 'sam-id'), media: samMedia, name: 'Sam');

    await maya.join();
    expect(maya.members, isEmpty);
    expect(mayaMedia.started, isTrue);

    await sam.join(withVideo: true);
    await _settle();
    // Sam came in: Sam offers, Maya answers, at Opus's highest.
    expect(samMedia.log, contains('offer to maya-id'));
    expect(mayaMedia.log, contains('answer sam-id (510k)'));
    expect(samMedia.log, contains('took answer from maya-id (stereo)'));
    expect(mayaMedia.log, contains('candidate from sam-id'));
    expect(mayaMedia.log.where((l) => l.startsWith('offer')), isEmpty, reason: 'two never offer each other');
    // Each knows the other by the name they gave, and that Sam's video is on.
    expect(maya.members['sam-id']!.name, 'Sam');
    expect(maya.members['sam-id']!.video, isTrue);
    expect(sam.members['maya-id']!.name, 'Maya');
    expect(samMedia.isVideo, isTrue);

    // Muted, deafened, video: said to the others.
    maya.setMuted(true);
    await _settle();
    expect(mayaMedia.isMuted, isTrue);
    expect(sam.members['maya-id']!.muted, isTrue);
    sam.setDeafened(true);
    await _settle();
    expect(samMedia.isDeaf, isTrue);
    expect(samMedia.isMuted, isTrue, reason: 'deafened is muted too');
    expect(maya.members['sam-id']!.muted, isTrue);
    await sam.setVideo(false);
    await _settle();
    expect(maya.members['sam-id']!.video, isFalse);

    // Out again any time.
    await sam.leave();
    await _settle();
    expect(maya.members, isEmpty);
    expect(mayaMedia.log, contains('closed sam-id'));
    expect(samMedia.started, isFalse);
    await maya.leave();
  });

  test('what is said in a channel is sealed with its key: a member with another key hears nothing', () async {
    final hub = _Hub();
    final c = VoiceChannel.make('Hangout');
    final other = VoiceChannel.make('x');
    final a = VoiceSession(channel: c, route: _Route(hub, 'a'), media: _Media(), name: 'A');
    final b = VoiceSession(channel: other, route: _Route(hub, 'b'), media: _Media(), name: 'B');
    await a.join();
    // The same room on the stand-in hub, a different key: as someone who got into the room without the seed.
    hub.rooms[other.room] = hub.rooms[c.room]!;
    await b.join();
    await _settle();
    expect(a.members['b']?.name ?? '', isEmpty);
    await a.leave();
    await b.leave();
  });

  // tool/voicebench, 2026-11-15: at 1080p and 12 Mb/s for everyone, three members fell to a frame a second.
  test('the picture is sized by how many others are in the call: full 1080p one to one, smaller as it grows', () {
    expect(videoFor(1), (scale: 1.0, bitrate: 12000000, preference: 'balanced'));
    expect(videoFor(2).scale, 1.5);
    expect(videoFor(3).bitrate, 2000000);
    expect(videoFor(4).scale, 2.0);
    expect(videoFor(7).scale, 3.0);
    // What a member sends at most, all copies together, stays under 12 Mb/s however many there are.
    for (var others = 1; others <= 10; others++) {
      expect(videoFor(others).bitrate * others, lessThanOrEqualTo(12000000), reason: '$others others');
    }
  });

  // Matt, 2026-11-14: "Make the voice hangouts possible to share via a link so people can join to talk anonymously or
  // sign up through the browser similar to a zoom meeting". tool/voicebench/join_test.mjs checks the page makes the
  // same room and token from this link.
  test('a hangout\'s link: the seed and the name after the #, which no server is sent', () {
    const c = VoiceChannel(seed: '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff', name: 'Friday hang ✨');
    expect(c.link, 'https://gogho.st/join/#00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff.RnJpZGF5IGhhbmcg4pyo');
    expect(c.room, '42c94d6559e4ea774004c9c5aa93e907');
    expect(c.token, '6ad07432d21d71cd131266a87b30ac1c84a167e5eea281ccdcee5cca2963ad64');
    expect(Uri.parse(c.link).path, '/join/', reason: 'the path is all a server sees');
  });

  test('a member who joined from a browser with no username is a guest', () async {
    final hub = _Hub();
    final c = VoiceChannel.make('Hangout');
    final a = VoiceSession(channel: c, route: _Route(hub, 'a'), media: _Media(), name: 'A');
    await a.join();
    final guest = _Route(hub, 'g');
    await guest.join(c.room, c.token);
    guest.send(c.room, NetCrypto.seal(c.key, utf8.encode(jsonEncode({'t': 'me', 'n': 'Alex', 'g': true}))));
    await _settle();
    expect(a.members['g']!.guest, isTrue);
    expect(a.members['g']!.name, 'Alex');
    await a.leave();
  });

  test('a username goes with a member\'s name, so the others can add them as a friend', () async {
    final hub = _Hub();
    final c = VoiceChannel.make('Hangout');
    final a = VoiceSession(channel: c, route: _Route(hub, 'a'), media: _Media(), name: 'Maya', username: 'maya');
    final b = VoiceSession(channel: c, route: _Route(hub, 'b'), media: _Media(), name: 'Sam');
    await a.join();
    await b.join();
    await _settle();
    expect(b.members['a']!.username, 'maya');
    expect(a.members['b']!.username, isNull);
    await a.leave();
    await b.leave();
  });

  // Matt, 2026-11-15: "make sure voice chats are kept actively in sync between mobile and desktop clients".
  test('the phone answers its computer: every channel with its group, a name to go by; and keeps one the computer made', () async {
    final v = Voice.instance;
    final mine = VoiceChannel.make('Friday hang');
    v.own = [mine];
    addTearDown(() => v.own = []);
    final list = await v.answerDesk({'op': 'list'}) as Map;
    expect([for (final c in list['channels'] as List) (c as Map)['s']], [mine.seed]);
    expect(((list['channels'] as List).first as Map)['m'], 1);
    final made = VoiceChannel.make('From the Mac');
    await v.answerDesk({'op': 'add', 's': made.seed, 'n': made.name});
    expect(v.own.map((c) => c.seed), [mine.seed, made.seed]);
    await v.answerDesk({'op': 'add', 's': made.seed, 'n': made.name});
    expect(v.own, hasLength(2), reason: 'kept once');
    await v.answerDesk({'op': 'forget', 's': made.seed});
    expect(v.own.map((c) => c.seed), [mine.seed]);
  });

  // GMFB-25 ("The app works fully against a self-hosted hub"): a computer paired with a phone made its own connection
  // for spaces to Uplink's relay whatever relay the phone used, so the two were in different rooms.
  test('the phone says which relay it uses where it is not Uplink\'s, and its computer\'s spaces go to that one', () async {
    final v = Voice.instance;
    // On Uplink's relay the phone says nothing of it, and its answer is what it always was.
    expect((await v.answerDesk({'op': 'list'}) as Map).containsKey('hub'), isFalse);
    // What a computer takes from the answer: a hub's address it can dial, or ours.
    expect(Voice.hubFromPhone('wss://relay.example.com/hub'), 'wss://relay.example.com/hub');
    expect(Voice.hubFromPhone('relay.example.com'), 'wss://relay.example.com/hub');
    expect(Voice.hubFromPhone('wss://gogho.st/hub'), isNull, reason: 'ours is the one used with nothing said');
    for (final not in [null, 7, '', 'not an address at all', 'ghost-relay://${'a' * 32}?n=${'b' * 64}', 'wss://${'x' * 400}.example.com/hub']) {
      expect(Voice.hubFromPhone(not), isNull, reason: '$not');
    }
    addTearDown(() => v.takePhoneHub(null));
    expect(v.pairedHubUrl, 'wss://gogho.st/hub');
    v.takePhoneHub('wss://relay.example.com/hub');
    expect(v.pairedHubUrl, 'wss://relay.example.com/hub');
    // A phone from before, or back on Uplink's relay, says none: ours again.
    v.takePhoneHub(null);
    expect(v.pairedHubUrl, 'wss://gogho.st/hub');
  });

  // Matt, 2026-11-24: "please see what you can do about the high CPU usage on the app". A paired computer asks for
  // this every eight seconds, and was sent every space and circle whole each time (lib/desk_stamp.dart).
  test('a computer that asks again is answered in a word while nothing has changed, and in full once something has', () async {
    final v = Voice.instance;
    final mine = VoiceChannel.make('Friday hang');
    v.own = [mine];
    addTearDown(() => v.own = []);
    final first = await v.answerDesk({'op': 'list'}) as Map;
    final stamp = first['stamp'] as String;
    expect(first['channels'], isNotEmpty);
    expect(await v.answerDesk({'op': 'list', 'have': stamp}), {'same': 1, 'stamp': stamp});
    // A space made on the phone since: the whole list, and a new mark.
    final more = VoiceChannel.make('Movie night');
    v.own = [mine, more];
    final after = await v.answerDesk({'op': 'list', 'have': stamp}) as Map;
    expect([for (final c in after['channels'] as List) (c as Map)['s']], [mine.seed, more.seed]);
    expect(after['stamp'], isNot(stamp));
    // A computer from before says no mark, and is answered in full as it always was.
    expect((await v.answerDesk({'op': 'list'}) as Map)['channels'], hasLength(2));
  });

  // Matt, 2026-11-15: "Removing a hangout channel doesn't remove it for all devices".
  test('a channel removed on the phone stays removed: its computer is told, and cannot hand it back', () async {
    final v = Voice.instance;
    final hang = VoiceChannel.make('Friday hang');
    v.own = [hang];
    addTearDown(() => v.own = []);
    await v.forget(hang);
    expect(v.own, isEmpty);
    // The computer, which had it and had not heard, offers it to the phone again: refused.
    final back = await v.answerDesk({'op': 'add', 's': hang.seed, 'n': hang.name}) as Map;
    expect(back['gone'], isTrue);
    expect(v.own, isEmpty);
    // And the list the computer reads says it is gone, so the computer takes it away too.
    final list = await v.answerDesk({'op': 'list'}) as Map;
    expect(list['gone'], contains(hang.seed));
    expect([for (final c in list['channels'] as List) (c as Map)['s']], isNot(contains(hang.seed)));
    // Removed from the computer: the phone marks it gone as well.
    final other = VoiceChannel.make('From the Mac');
    await v.answerDesk({'op': 'add', 's': other.seed, 'n': other.name});
    await v.answerDesk({'op': 'forget', 's': other.seed});
    expect(v.removed(other.seed), isTrue);
    expect((await v.answerDesk({'op': 'add', 's': other.seed, 'n': other.name}) as Map)['gone'], isTrue);
  });

  // Matt, 2026-11-16: "I want the bot to connect and act as my voice": a space bridged to Discord has the bridge as a
  // member, which says who is in the Discord voice channel and who is talking there.
  test('the bridge to Discord says who is in the Discord channel; the session keeps them, and their talking', () async {
    final hub = _Hub();
    final c = VoiceChannel.make('General');
    final me = VoiceSession(channel: c, route: _Route(hub, 'me-id'), media: _Media(), name: 'Me');
    final bridge = _Route(hub, 'bridge-id');
    await bridge.join(c.room, c.token);
    await me.join();
    await _settle();
    void say(Map<String, Object?> what) => bridge.send(c.room, NetCrypto.seal(c.key, utf8.encode(jsonEncode(what))));
    say({'t': 'me', 'n': 'Discord', 'm': false, 'v': false});
    say({
      't': 'dc',
      'people': [
        {'id': 'u1', 'name': 'Alex', 'speaking': true, 'muted': false, 'deafened': false, 'bot': false},
        {'id': 'u2', 'name': 'Sam', 'speaking': false, 'muted': true, 'deafened': false, 'bot': false},
        {'id': 'b', 'name': 'Some bot', 'bot': true},
      ],
    });
    await _settle();
    expect(me.bridgeId, 'bridge-id');
    expect(me.discordPeople.map((p) => p.name), ['Alex', 'Sam', 'Some bot']);
    expect(me.discordLevels.value['dc:u1'], greaterThan(0.04), reason: 'talking in Discord ripples here');
    expect(me.discordLevels.value['dc:u2'], 0, reason: 'muted is not talking');
    // A later word replaces it.
    say({'t': 'dc', 'people': [{'id': 'u2', 'name': 'Sam', 'speaking': true}]});
    await _settle();
    expect(me.discordPeople.single.name, 'Sam');
    expect(me.discordLevels.value.keys, ['dc:u2']);
    await me.leave();
  });

  test('a call starts through the relay alone, and where that fails the side that offered starts over trying every path', () async {
    // Matt, 2026-11-21: "Sometimes calls are not negotiating in voice chats and I can't connect to another person, if
    // p2p fails please connect over voice through the relay", then "Try to negotiate over the relay first".
    final hub = _Hub();
    final c = VoiceChannel.make('Lounge');
    final mayaMedia = _Fallback(), samMedia = _Fallback();
    final maya = VoiceSession(channel: c, route: _Route(hub, 'maya-id'), media: mayaMedia, name: 'Maya');
    final sam = VoiceSession(channel: c, route: _Route(hub, 'sam-id'), media: samMedia, name: 'Sam');
    await maya.join();
    await sam.join();
    await _settle();
    expect(samMedia.log, containsAllInOrder(['made maya-id (relay only)', 'offer to maya-id', 'took answer from maya-id (stereo)']), reason: 'Sam came in, so Sam offers, through the relay');
    expect(mayaMedia.log, containsAllInOrder(['made sam-id (relay only)', 'answer sam-id (510k)']), reason: 'Maya answers through the relay too');

    // Maya's side failing waits: Sam offered, so Sam starts over.
    mayaMedia.log.clear();
    samMedia.log.clear();
    mayaMedia.fail['sam-id']!();
    await _settle();
    expect(samMedia.log, isEmpty);
    expect(mayaMedia.log, isEmpty);

    samMedia.fail['maya-id']!();
    await _settle();
    expect(samMedia.log, containsAllInOrder(['closed maya-id', 'made maya-id', 'offer to maya-id']));
    expect(samMedia.log, isNot(contains('made maya-id (relay only)')));
    expect(mayaMedia.log, containsAllInOrder(['closed sam-id', 'made sam-id', 'answer sam-id (510k)']), reason: 'Maya lets go of the failed one and answers on every path too');
    expect(samMedia.relayOnlyOf['maya-id'], isFalse);
    expect(mayaMedia.relayOnlyOf['sam-id'], isFalse);

    // Once only: a second failure is left as it is.
    samMedia.log.clear();
    samMedia.fail['maya-id']!();
    await _settle();
    expect(samMedia.log, isEmpty);

    // Sam leaves and comes back: through the relay again, and a fresh fallback.
    await sam.leave();
    await _settle();
    samMedia.log.clear();
    await sam.join();
    await _settle();
    expect(samMedia.log, contains('made maya-id (relay only)'));
    samMedia.log.clear();
    samMedia.fail['maya-id']!();
    await _settle();
    expect(samMedia.log, contains('made maya-id'));
    await maya.leave();
    await sam.leave();
  });

  test('the side that answers goes through the relay where the offer says so, whatever it was handed itself', () async {
    final hub = _Hub();
    final c = VoiceChannel.make('Lounge');
    final mayaMedia = _Fallback(hasRelay: false), samMedia = _Fallback();
    final maya = VoiceSession(channel: c, route: _Route(hub, 'maya-id'), media: mayaMedia, name: 'Maya');
    final sam = VoiceSession(channel: c, route: _Route(hub, 'sam-id'), media: samMedia, name: 'Sam');
    await maya.join();
    await sam.join();
    await _settle();
    expect(mayaMedia.relayOnlyOf['sam-id'], isTrue);
    await maya.leave();
    await sam.leave();
  });

  test('with no relay handed out, a failed connection is left as it was', () async {
    final hub = _Hub();
    final c = VoiceChannel.make('Lounge');
    final mayaMedia = _Fallback(hasRelay: false), samMedia = _Fallback(hasRelay: false);
    final maya = VoiceSession(channel: c, route: _Route(hub, 'maya-id'), media: mayaMedia, name: 'Maya');
    final sam = VoiceSession(channel: c, route: _Route(hub, 'sam-id'), media: samMedia, name: 'Sam');
    await maya.join();
    await sam.join();
    await _settle();
    samMedia.log.clear();
    samMedia.fail['maya-id']!();
    await _settle();
    expect(samMedia.log, isEmpty);
    await maya.leave();
    await sam.leave();
  });

  test('sharing a screen (GMFB-27): said to the others as a screen and as video, stopped by Stop or by the system', () async {
    final hub = _Hub();
    final c = VoiceChannel.make('Hangout');
    final mayaMedia = _Screens();
    final maya = VoiceSession(channel: c, route: _Route(hub, 'maya-id'), media: mayaMedia, name: 'Maya');
    final sam = VoiceSession(channel: c, route: _Route(hub, 'sam-id'), media: _Media(), name: 'Sam');
    await maya.join();
    await sam.join();
    await _settle();
    expect(maya.canShareScreen, isTrue);
    expect(sam.canShareScreen, isFalse, reason: 'media that cannot capture a screen');
    expect(await sam.setScreen(true), isFalse);

    expect(await maya.setScreen(true, source: 'screen:0'), isTrue);
    await _settle();
    expect(mayaMedia.sharing, 'screen:0');
    expect(maya.screen, isTrue);
    // Video is said too, so a build that knows nothing of sharing still shows the picture.
    expect(sam.members['maya-id']!.screen, isTrue);
    expect(sam.members['maya-id']!.video, isTrue);

    // Stopped with Stop: back to no picture, as her camera was off.
    await maya.setScreen(false);
    await _settle();
    expect(mayaMedia.sharing, isNull);
    expect(sam.members['maya-id']!.screen, isFalse);
    expect(sam.members['maya-id']!.video, isFalse);

    // With her camera on, the camera is what is said once the screen stops.
    await maya.setVideo(true);
    await maya.setScreen(true, source: 'screen:0');
    await _settle();
    expect(sam.members['maya-id']!.screen, isTrue);
    // Stopped by the system (its own Stop sharing, the window closed).
    mayaMedia.systemStop();
    await _settle();
    expect(maya.screen, isFalse);
    expect(sam.members['maya-id']!.screen, isFalse);
    expect(sam.members['maya-id']!.video, isTrue, reason: 'her camera is still on');

    // The person said no to the system's question: nothing is said.
    mayaMedia.refuse = true;
    expect(await maya.setScreen(true), isFalse);
    await _settle();
    expect(maya.screen, isFalse);
    expect(sam.members['maya-id']!.screen, isFalse);

    // A role that may not show video may not share either.
    mayaMedia.refuse = false;
    maya.videoLocked = true;
    expect(await maya.setScreen(true, source: 'screen:0'), isFalse);
    expect(mayaMedia.sharing, isNull);
    await maya.leave();
    await sam.leave();
  });

  test('a shared screen keeps its words sharp: at least 2.5 Mb/s, and 1080 lines at most', () {
    expect(RtcMedia.screenBitrate(1500000), 2500000);
    expect(RtcMedia.screenBitrate(12000000), 12000000);
    expect(RtcMedia.screenScale(null), 1.0);
    expect(RtcMedia.screenScale(900), 1.0, reason: 'never scaled up');
    expect(RtcMedia.screenScale(2160), 2.0);
  });
}
