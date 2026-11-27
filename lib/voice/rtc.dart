import 'dart:async';
import 'dart:math' as math;
import '../app_seen.dart';
import '../platform_info.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'call_sound.dart';
import 'screen_sound.dart';
import 'voice.dart';
import 'voice_fx.dart';
import 'voice_settings.dart';

/// The microphone, the camera and a WebRTC connection to each other member (lib/voice/voice.dart says what goes
/// between them and how).
///
/// Sound is taken at 48 kHz, in stereo or mono, with echo cancellation, automatic gain and noise suppression each as
/// Settings › Voice has it ([_audioAsked]), and sent as Opus at the rate chosen there, 510 kb/s unless changed.
/// Each connection carries one sound and one picture both ways from its start; turning video on or off
/// puts the camera's picture in or takes it out, with nothing to work out again between the two.
class RtcMedia implements VoiceMedia, FallbackMedia, ScreenMedia, ScreenSoundMedia, LinkedMedia, CameraMedia, SoundMedia, PlacedMedia, PictureMedia {
  RtcMedia({this.relay, this.settings = const VoiceSettings(), this.light = false});

  /// Settings' microphone test, made light where the native half can say how loud the microphone is (the Mac's,
  /// VoiceFx.level): the microphone is started by itself, off the main thread, and no meter is made, unless the test
  /// is to be heard (GMFB-20, Matt, Mac 0.12.5: "it's laggy and shows the pinwheel when starting a microphone test in
  /// settings"). The meter is two connections to each other, and on the Mac flutter_webrtc makes, negotiates and
  /// closes them on the main thread, each step waiting while WebRTC starts or stops the sound device.
  final bool light;

  /// The microphone recording by itself ([light]), with no connection sending it.
  bool _local = false;

  /// The devices, Opus and processing, and the picture's quality, as Settings › Voice has them.
  VoiceSettings settings;

  /// The servers a connection asks for its own public address where no others are given: public STUN only, no relay.
  static const defaultIce = [
    {
      'urls': ['stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302'],
    },
  ];

  /// The relay's TURN server for calls as the hub last handed it out with a room joined (relay/lib/turn.dart,
  /// HubCarrier.callRelay), asked for as each connection is made; null or none: direct only.
  final Map<String, Object>? Function()? relay;

  /// Where a connection looks for a way through: the public STUN servers, and the relay where there is one. WebRTC
  /// tries them all at once and takes the best that works, so a call goes direct wherever it can and through the
  /// relay only where it can't.
  List<Map<String, Object>> get iceServers => [...defaultIce, ?relay?.call()];

  @override
  bool get hasRelay => relay?.call() != null;

  MediaStream? _mic;
  MediaStream? _cam;

  /// The screen or window this device is sharing (GMFB-27): sent in the camera's place while there is one.
  MediaStream? _screen;

  @override
  final ValueNotifier<MediaStream?> localScreen = ValueNotifier(null);

  /// Said before a phone's screen is captured and after it stops: the call's service takes on, or drops, the media
  /// projection kind Android 14 asks for (lib/voice/channels.dart).
  Future<void> Function(bool sharing)? screenService;

  /// How tall the shared screen is, where WebRTC says: it is sent at 1080 lines at most.
  double? _screenHeight;

  /// What the computer plays, with the screen it shares (GMFB-63; lib/voice/screen_sound.dart). A PC's is a track
  /// flutter_webrtc makes beside the screen's own: everything the PC plays but this app's sound for a whole screen,
  /// the one app's for a window. A Mac's is a tap of this app's making (macos/Runner/ScreenSound.swift), since the
  /// plugin gives a Mac none. Nowhere else: Linux's sound system gives only everything the computer plays, the call
  /// among it, and everyone would be sent their own voice back; a phone's is not built.
  @override
  bool screenWithSound = false;
  ShareSoundSource? _screenSound;
  @override
  ShareSoundSource? get screenSound => _screenSound;

  @override
  Future<bool> screenSoundSupported() async {
    if (kIsWeb) return false;
    if (PlatformInfo.isWindows) return true;
    if (PlatformInfo.isMacOS) return MacShareSound.able();
    return false;
  }

  /// This device's camera while video is on, for its own tile.
  final ValueNotifier<MediaStream?> localVideo = ValueNotifier(null);

  /// Each other member's picture, by their id: a stream made on this device holding the video track their connection
  /// receives, for their tile ([_RtcPeer._took]).
  final ValueNotifier<Map<String, MediaStream>> remote = ValueNotifier(const {});

  /// Each other member's sound, by their id: the track their connection receives it on, for a recording to tap
  /// (GMFB-52). [remote] holds pictures only, so a recording that looked there for a voice found nobody's.
  @override
  final ValueNotifier<Map<String, VoiceSound>> sounds = ValueNotifier(const {});

  /// Each other member's picture, for a recording that takes video to draw (GMFB-42): the video track their tile
  /// draws from [remote], with their connection's mark.
  @override
  Map<String, VoiceSound> get pictures => {
        for (final e in _peers.entries)
          if (e.value._view?.getVideoTracks().firstOrNull?.id case final String track) e.key: (track: track, link: identityHashCode(e.value)),
      };

  /// What this device sends as its picture: the screen while it shares, else the camera while video is on.
  @override
  ({String track, bool screen})? get ownPicture {
    final id = _picture?.id;
    return id == null ? null : (track: id, screen: sharing);
  }

  @override
  late final Listenable pictureChanges = Listenable.merge([remote, localVideo, localScreen]);
  final Map<String, _RtcPeer> _peers = {};
  bool _deaf = false;

  // This device's own choices for each other member: how loud they are played (0 to 2) and who is silenced here.
  final Map<String, double> _volume = {};
  final Set<String> _silenced = {};

  /// Each one's sound as this device plays it: silenced (deafened, or that one muted here) or at their volume.
  void _apply(String id) {
    for (final t in _peers[id]?._sounds ?? const <MediaStreamTrack>[]) {
      t.enabled = !_deaf && !_silenced.contains(id);
      // Each person's own volume times the output volume (Settings › Voice and video), boosted to twice at most, and
      // times the auto leveler's gain for them where it is on (leveler.dart).
      // And, in an open space, times how much of them is heard from where this device stands (open_space.dart).
      final v = ((_volume[id] ?? 1.0) * settings.outputVolume / 100 * (_leveled[id] ?? 1.0) * (_placed[id] ?? 1.0)).clamp(0.0, 6.0);
      if (CallSound.playsItself) {
        _out.set(id, volume: v, silent: !t.enabled);
      } else {
        unawaited(Helper.setVolume(v, t).catchError((_) {}));
      }
    }
  }

  /// Where the app plays what arrives itself (a browser: lib/voice/call_sound.dart), what plays it.
  final CallSound _out = CallSound();

  /// How much of each person is heard from where this device stands in an open space (open_space.dart): 1 is all.
  final Map<String, double> _placed = {};

  @override
  void setPlaceGain(String id, double gain) {
    if (gain >= 1) {
      if (_placed.remove(id) == null) return;
    } else {
      _placed[id] = gain.clamp(0.0, 1.0);
    }
    _apply(id);
  }

  /// The auto leveler's gain for each person (leveler.dart): 1 is as they arrive.
  final Map<String, double> _leveled = {};

  /// Sets it for [id], held between a quarter and three and a half times; 1 takes it away.
  void setLevelGain(String id, double gain) {
    if (gain == 1) {
      if (_leveled.remove(id) == null) return;
    } else {
      _leveled[id] = gain.clamp(0.25, 3.5);
    }
    _apply(id);
  }

  @override
  void setPeerVolume(String id, double volume) {
    _volume[id] = volume.clamp(0.0, 2.0);
    _apply(id);
  }

  @override
  void setPeerMuted(String id, bool muted) {
    muted ? _silenced.add(id) : _silenced.remove(id);
    _apply(id);
  }

  @override
  final ValueNotifier<Map<String, double>> levels = ValueNotifier(const {});

  /// How this device's connection to each person stands, by their id ([PeerLink]): drawn on their face and row.
  final ValueNotifier<Map<String, PeerLink>> links = ValueNotifier(const {});

  /// Whether the microphone has been heard at all since the call began: false from [start] until a reading has its
  /// level. On a Mac the system's sound takes about three seconds to start (Apple's audio engine and its voice
  /// processing: docs/performance-audit.md) and nothing connects meanwhile, so the screens say that the microphone
  /// is starting (lib/voice/call_wait.dart) and not nothing.
  final ValueNotifier<bool> micLive = ValueNotifier(false);

  /// Sets how the connection to [id] stands; null takes them out of [links].
  void _link(String id, PeerLink? to) {
    final now = links.value;
    if (now[id] == to) return;
    links.value = to == null ? ({...now}..remove(id)) : {...now, id: to};
  }
  Timer? _levelTimer;

  /// How often the levels are read while a face can be seen rippling.
  static const levelEvery = Duration(milliseconds: 150);

  /// How often each connection's round trip is read for [links], where the levels themselves need no statistics.
  static const linkEvery = Duration(seconds: 3);
  DateTime? _linksReadAt;

  /// Whether the call is on: between [start] and [stop].
  bool _on = false;

  /// The app was put away or brought back ([AppSeen]): how loud each voice is is read only while a face can be seen
  /// rippling. Put away, the readings stop, every face rests, and the meter that measures this device's own voice
  /// while it is alone in the call is closed, so a phone left alone in a space with its screen off runs no sound at
  /// all (it ran a whole call to itself: docs/performance-audit.md, "Calls"). Brought back, they begin again at once.
  void _seenChanged() {
    if (!_on) return;
    if (AppSeen.now.value) {
      _levelTimer ??= Timer.periodic(levelEvery, (_) => _readLevels());
      unawaited(_readLevels());
    } else {
      _levelTimer?.cancel();
      _levelTimer = null;
      levels.value = const {};
      unawaited(_closeMeter());
    }
    // The native half's taps on each voice go with the readings, and come back with them.
    unawaited(_syncTaps());
  }

  /// The voices the native half is tapping for their level ([VoiceFx.hear]), by whose they are, as [sounds] named
  /// them; and those it could not tap, which are read from their connection's statistics until their sound changes.
  final Map<String, VoiceSound> _taps = {};
  final Map<String, VoiceSound> _untapped = {};
  bool _tapping = false;

  /// Has the native half tap each voice [sounds] names, and let go of those gone, where it measures levels itself
  /// ([VoiceFx.levelsSupported]: the phone). One pass at a time, again while what is wanted changed meanwhile.
  Future<void> _syncTaps() async {
    if (!VoiceFx.levelsSupported || _tapping) return;
    _tapping = true;
    try {
      while (true) {
        // Only while a face can be seen rippling ([_seenChanged]): a tap is WebRTC handing over every block of a voice,
        // which is work on its sound thread that nobody is looking at the result of.
        final want = _on && AppSeen.now.value ? sounds.value : const <String, VoiceSound>{};
        _untapped.removeWhere((id, s) => want[id] != s);
        final gone = [for (final id in _taps.keys) if (!want.containsKey(id)) id];
        final fresh = [for (final e in want.entries) if (_taps[e.key] != e.value && _untapped[e.key] != e.value) e];
        if (gone.isEmpty && fresh.isEmpty) break;
        for (final id in gone) {
          _taps.remove(id);
          await VoiceFx.unhear(id);
        }
        for (final e in fresh) {
          if (await VoiceFx.hear(e.key, e.value.track)) {
            _taps[e.key] = e.value;
          } else {
            _taps.remove(e.key);
            _untapped[e.key] = e.value;
          }
        }
      }
    } finally {
      _tapping = false;
    }
  }

  /// A connection that holds the microphone and never connects: what this device's own level is read from, alone in a
  /// call or with others (Matt, 2026-11-15: "on desktop it doesn't seem like when i'm talking i see the wobbles coming
  /// from my voice chat"). It was read from the connections to the others alone, so alone in a call, and wherever
  /// those had not yet said it, the face had nothing to ripple with.
  RTCPeerConnection? _meter;

  /// The meter's other end, on this device: the meter is connected to it, so the microphone is really sending even
  /// with nobody else in the call (Matt, 2026-11-16: "make it so that even when we're in the call alone we see the
  /// voice activity of ourselves"). A sender that never connects is never started on Android's and the Mac's WebRTC,
  /// and gave no level at all. What arrives here is silenced: nobody hears themselves.
  RTCPeerConnection? _meterSink;

  /// The microphone's total energy and the seconds it covers, as last read: a level is worked out from how much each
  /// grew ([_micLevel]).
  double? _energy, _energyTime;

  /// How loud the microphone is from a media source's numbers: its own level where it gives one, else from the
  /// energy it has heard over the time it has heard it (the two WebRTC keeps; the Mac's has given the second only).
  double? _micLevel(Map<dynamic, dynamic> v) {
    if (v['audioLevel'] is num) return (v['audioLevel'] as num).toDouble();
    final e = v['totalAudioEnergy'], d = v['totalSamplesDuration'];
    if (e is! num || d is! num) return null;
    final was = _energy, wasTime = _energyTime;
    _energy = e.toDouble();
    _energyTime = d.toDouble();
    if (was == null || wasTime == null || _energyTime! <= wasTime) return null;
    return math.sqrt(((_energy! - was) / (_energyTime! - wasTime)).clamp(0.0, 1.0));
  }

  /// Reads how loud each sound is, several times a second (WebRTC's audioLevel: the incoming sound's at each
  /// connection, the microphone's at its media source), eased so a face does not flicker between words.
  Future<void> _readLevels() async {
    // One reading at a time: when the app is busy (an upload sealing beside the call), readings that overlapped piled
    // up getStats on the platform channel and made it busier still (GMFB-6).
    if (_reading) return;
    _reading = true;
    try {
      await _readLevelsOnce();
    } finally {
      _reading = false;
    }
  }

  bool _reading = false;

  /// Connected, or poor where a word takes longer than [poorAfter] there and back.
  static const poorAfter = 0.4;
  @visibleForTesting
  static PeerLink linkFor(double roundTrip) => roundTrip > poorAfter ? PeerLink.poor : PeerLink.connected;

  /// One reading: this device's own level, then each connection's, into [levels].
  Future<void> _readLevelsOnce() async {
    final next = <String, double>{};
    // Where the native half measures the voices itself (the phone, android VoiceFx.kt), one small answer holds them
    // all and no connection is asked for its statistics for them. Believed only with the microphone's own in it:
    // without (the hook not yet in WebRTC's path), everything is read as it always was.
    final tapped = <String>{};
    if (VoiceFx.levelsSupported && _peers.isNotEmpty) {
      final said = await VoiceFx.levels();
      if (said != null && said.containsKey('me')) {
        next['me'] = said['me']!;
        for (final id in _taps.keys) {
          final l = said[id];
          if (l != null && _peers.containsKey(id)) {
            next[id] = l;
            tapped.add(id);
          }
        }
      }
    }
    final meter = _meter;
    if (meter != null) {
      try {
        for (final r in await meter.getStats()) {
          if ((r.type == 'media-source' || r.type == 'track') && r.values['kind'] == 'audio' && r.values['remoteSource'] != true) {
            final l = _micLevel(r.values);
            if (l != null) next['me'] = l;
          }
        }
      } catch (_) {}
    }
    // A light test with nothing to be heard: the native half says how loud the microphone is ([light]).
    if (_local && meter == null) next['me'] = await VoiceFx.level();
    // The meter while alone, not with others (_openMeter, _closeMeter); a light test has one only to be heard.
    if (_peers.isEmpty && _meter == null && !_opening && (!_local || hearMyself) && AppSeen.now.value) {
      unawaited(_openMeter());
    } else if (_peers.isNotEmpty && _meter != null) {
      unawaited(_closeMeter());
    }
    // What reaches the meter's other end is never heard: held to silence at every reading, not trusted to one event
    // (Matt, 2026-11-16: "I can hear myself also if I mute and unmute in a space": on the phone the track was played).
    // Told again only what has changed; and on Android the connection is asked for its receivers every two seconds.
    _sinceAsked++;
    final ask = _asksReceivers && _sinceAsked >= 13;
    if (ask) _sinceAsked = 0;
    unawaited(_silenceSink(ask: ask));
    // Where the sender says nothing, the level of what reached the meter's other end.
    final sink = _meterSink;
    if (sink != null && !next.containsKey('me')) {
      try {
        for (final r in await sink.getStats()) {
          final v = r.values;
          if (r.type == 'inbound-rtp' && v['kind'] == 'audio' && v['audioLevel'] is num) next['me'] = (v['audioLevel'] as num).toDouble();
        }
      } catch (_) {}
    }
    // Muted, this device is not talking, whatever the microphone still hears.
    if (_mic?.getAudioTracks().any((t) => t.enabled) == false) next['me'] = 0;
    // A connection's statistics: for the level of a voice the native half does not measure, at every reading; and for
    // everyone's round trip, every [linkEvery].
    final now = DateTime.now();
    final linksDue = _linksReadAt == null || now.difference(_linksReadAt!) >= linkEvery;
    if (linksDue) _linksReadAt = now;
    for (final e in _peers.entries.toList()) {
      final made = e.value._pc;
      if (made == null) continue;
      final byStats = !tapped.contains(e.key);
      if (!byStats && !linksDue) continue;
      try {
        final pc = await made;
        double? rtt;
        for (final r in await pc.getStats()) {
          final v = r.values;
          // How long a word takes there and back, on the way in use (GMFB-4): over 400 ms a call is hard to talk on.
          if (r.type == 'candidate-pair' && (v['nominated'] == true || v['state'] == 'succeeded') && v['currentRoundTripTime'] is num) {
            rtt = math.max(rtt ?? 0, (v['currentRoundTripTime'] as num).toDouble());
          }
          if (byStats && r.type == 'inbound-rtp' && v['kind'] == 'audio' && v['audioLevel'] is num) next[e.key] = (v['audioLevel'] as num).toDouble();
          if (r.type == 'media-source' && v['kind'] == 'audio' && v['audioLevel'] is num && !next.containsKey('me')) next['me'] = (v['audioLevel'] as num).toDouble();
        }
        final link = links.value[e.key];
        if (rtt != null && (link == PeerLink.connected || link == PeerLink.poor)) _link(e.key, linkFor(rtt));
      } catch (_) {}
    }
    // The microphone has been heard, or is known to be off: it has started ([micLive]).
    if (_on && next.containsKey('me')) micLive.value = true;
    // Put away while this was being read: every face is at rest, and stays so ([_seenChanged]).
    if (!AppSeen.now.value || !_on) return;
    final was = levels.value;
    final eased = {for (final k in {...was.keys, ...next.keys}) k: _ease(was[k] ?? 0, next[k] ?? 0)};
    // Told only when a face would move: a new map each reading had every listener rebuild seven times a second while
    // nobody spoke (GMFB-6).
    final moved = eased.length != was.length || eased.entries.any((e) => ((was[e.key] ?? -1) - e.value).abs() > 0.01);
    if (moved) levels.value = eased;
  }

  /// The meter is being opened: a second reading in the meantime doesn't open another.
  bool _opening = false;

  /// What the ids of the meter partner's copy of the microphone start with ([_openMeter]).
  static const meterPrefix = 'ghost-meter-';

  /// [sdp] (the meter's offer) with the microphone's track and stream ids given the meter's own prefix, so the
  /// partner's copy is a track of its own to flutter_webrtc and switching it off never touches the microphone.
  @visibleForTesting
  static String meterApart(String sdp, {required String trackId, required String streamId}) =>
      sdp.replaceAll(trackId, '$meterPrefix$trackId').replaceAll(streamId, '$meterPrefix$streamId');

  /// Opens the meter and its silent partner, for this device's own level while it is alone in the call.
  Future<void> _openMeter() async {
    final mic = _mic;
    if (_meter != null || _opening || mic == null) return;
    _opening = true;
    try {
      final config = {'iceServers': <Map<String, Object>>[], 'sdpSemantics': 'unified-plan'};
      final meter = await createPeerConnection(config);
      final sink = await createPeerConnection(config);
      // Connected on this device alone: each end's ways to connect handed straight to the other.
      meter.onIceCandidate = (c) {
        if (c.candidate != null) unawaited(sink.addCandidate(c).catchError((_) {}));
      };
      sink.onIceCandidate = (c) {
        if (c.candidate != null) unawaited(meter.addCandidate(c).catchError((_) {}));
      };
      // What arrives is never played: each copy of the microphone it is handed is kept ([_sinkTracks]) and silenced.
      _sinkTracks.clear();
      _sinkQuiet.clear();
      sink.onTrack = (e) {
        _noteConnection(sink, e.track);
        final t = e.track;
        if (t.kind == 'audio' && (t.id ?? '').startsWith(meterPrefix) && !_sinkTracks.any((x) => x.id == t.id)) _sinkTracks.add(t);
        unawaited(_silenceSink());
      };
      final sending = await meter.addTransceiver(
        track: mic.getAudioTracks().first,
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        // Low: only its level is wanted.
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendOnly, streams: [mic], sendEncodings: [RTCRtpEncoding(maxBitrate: 16000)]),
      );
      _noteConnection(meter, sending.sender);
      final offer = await meter.createOffer();
      await meter.setLocalDescription(offer);
      // The partner's copy of the microphone gets ids of its own. flutter_webrtc finds a track by its id, looking at
      // this device's own tracks first, so under the microphone's id "switch off the partner's copy" switched off
      // the microphone itself, and the copy was played (Matt, 2026-11-16: "I can hear myself also if I mute and
      // unmute in a space"; "I cant hear the other person that joined the space"). With no ids to change, no meter.
      final micTrack = mic.getAudioTracks().first;
      final trackId = micTrack.id;
      final sdp = offer.sdp ?? '';
      if (trackId == null || trackId.isEmpty || !sdp.contains(trackId)) {
        await closeConnection(meter);
        await closeConnection(sink);
        _opening = false;
        return;
      }
      final apart = meterApart(sdp, trackId: trackId, streamId: mic.id);
      await sink.setRemoteDescription(RTCSessionDescription(apart, offer.type));
      final answer = await sink.createAnswer();
      await sink.setLocalDescription(answer);
      await meter.setRemoteDescription(answer);
      _meterSink = sink;
      await _silenceSink();
      _meter = meter;
    } catch (_) {}
    _opening = false;
    // Put away, or the call ended, while it was being opened: nothing is left measuring.
    if (!AppSeen.now.value || !_on) await _closeMeter();
  }

  /// Closes the meter once someone else is in the call: their connections measure the microphone from then on, and
  /// nothing of this device's own sound is looped back while anyone is listening.
  Future<void> _closeMeter() async {
    final meter = _meter, sink = _meterSink;
    _meter = null;
    _meterSink = null;
    _energy = null;
    _energyTime = null;
    _sinkTracks.clear();
    _sinkQuiet.clear();
    if (meter != null) await closeConnection(meter);
    if (sink != null) await closeConnection(sink);
  }

  /// The copies of the microphone the meter's other end has been handed, as its `onTrack` said, and which of them
  /// were last told to be quiet (by their ids): what [_silenceSink] works from.
  final List<MediaStreamTrack> _sinkTracks = [];
  final Map<String, bool> _sinkQuiet = {};

  /// How many readings since the meter's other end was last asked for its receivers ([_silenceSink] `ask`).
  int _sinceAsked = 0;

  /// Switches off every track the meter's other end receives and turns it to nothing, so this device never plays its
  /// own microphone back.
  ///
  /// It works from the tracks the connection announced ([_sinkTracks]) and says something to the platform only when
  /// a track is new or what it should be has changed. It used to ask the connection for its receivers at every
  /// reading, 6.7 times a second. On a Mac that question is answered by WebRTC's worker thread and the app's main
  /// thread waits for the answer, and while WebRTC starts the microphone the worker is busy for about three seconds
  /// (the system's audio engine and its voice processing): the whole window froze, under a pinwheel, each time a call
  /// was joined alone (Matt, 2026-11-24: "connecting to a call still freezes the mac and shows a pinwheel animation";
  /// sampled on his MacBook Air: 3.2 s in `-[RTCRtpReceiver parameters]` under `getReceivers`, the worker in
  /// `AudioEngineDevice::InitRecording`). [ask] asks all the same, for a phone whose receiver's track is made, or made
  /// again, without the event that announces it: Android alone, every two seconds ([_readLevelsOnce]).
  Future<void> _silenceSink({bool ask = false}) async {
    final sink = _meterSink;
    if (sink == null) return;
    // The audio test alone, never a call: the copy played back through the speaker chosen ([hearMyself]).
    final hear = hearMyself && _peers.isEmpty;
    if (ask) {
      try {
        for (final r in await sink.getReceivers()) {
          final t = r.track;
          // Only the partner's own copy, by the ids given it: never the microphone.
          if (t == null || t.kind != 'audio' || !(t.id ?? '').startsWith(meterPrefix)) continue;
          // The one held by that id may be an older making of it: this one is what plays now.
          _sinkTracks.removeWhere((x) => x.id == t.id);
          _sinkTracks.add(t);
          _sinkQuiet.remove(t.id);
        }
      } catch (_) {}
    }
    for (final track in _sinkTracks.toList()) {
      try {
        if (track.enabled != hear) track.enabled = hear;
        // A browser plays nothing it isn't given to play (call_sound.dart): the copy is never given.
        final id = track.id ?? '';
        if (!CallSound.playsItself && _sinkQuiet[id] != !hear) {
          _sinkQuiet[id] = !hear;
          await Helper.setVolume(hear ? 1 : 0, track).catchError((_) {});
        }
      } catch (_) {}
    }
  }

  /// Whether the meter's other end is asked for its receivers now and then ([_silenceSink]): on Android, where a
  /// receiver's track has been made again without saying so. Nowhere else: on a Mac the asking can hold the window.
  static bool get _asksReceivers => !kIsWeb && PlatformInfo.isAndroid;

  // --- closing a connection without holding the window ----------------------------------------------------------------

  /// Each connection's name on the platform, where it has been learnt ([_noteConnection]).
  static final Expando<String> _connectionIds = Expando<String>('rtc connection');

  /// Remembers [pc]'s name on the platform from something of its that carries it ([from]: a sender, a receiver or a
  /// track flutter_webrtc made for it), for [closeConnection]. Nothing is asked of the platform for it.
  static void _noteConnection(RTCPeerConnection pc, Object? from) {
    if (from == null || _connectionIds[pc] != null) return;
    try {
      final id = (from as dynamic).peerConnectionId;
      if (id is String && id.isNotEmpty) _connectionIds[pc] = id;
    } catch (_) {
      // Not one of the platform's own (a browser's, a test's): closed the usual way.
    }
  }

  /// [_noteConnection], for a connection made beside the call's own (the music's: lib/voice/spotify_link.dart), so that
  /// it too is closed off the main thread.
  static void note(RTCPeerConnection pc, Object? from) => _noteConnection(pc, from);

  /// A connection beside the call's own: WebRTC's, or a test's ([connect]).
  static Future<RTCPeerConnection> make(Map<String, dynamic> configuration) => (connect ?? createPeerConnection)(configuration);

  /// Closes [pc]. On a Mac the native half closes it first, off the main thread ([VoiceFx.closeAside]): closing waits
  /// for WebRTC to stop its sound, the system takes seconds over that, and flutter_webrtc closes on the main thread,
  /// so the window froze as a call ended (Matt, 2026-11-24: "it lagged on the call end"; sampled: 2.6 s in
  /// `PeerConnection::Close`). The plugin's own close then finds it closed and comes straight back.
  static Future<void> closeConnection(RTCPeerConnection pc) async {
    final id = _connectionIds[pc];
    if (id != null && VoiceFx.closesAside) await VoiceFx.closeAside(id);
    await pc.close();
  }

  /// Settings' audio test (GMFB-2, @kevin: "When testing voice calls it is difficult to diagnose issues without an in
  /// app audio device test"): the microphone played back through the speaker chosen, so both are heard as a call
  /// would use them. Only ever while nobody else is connected; a call's sink stays silent whatever this says.
  bool hearMyself = false;

  static double _ease(double from, double to) => to > from ? from + (to - from) * 0.6 : from + (to - from) * 0.25;

  /// The most sound is sent at, in bits a second, as the settings ask.
  int get audioBitrate => settings.sendKbps * 1000;

  /// Stands in for the system's list of devices (a test, with no WebRTC underneath).
  @visibleForTesting
  static Future<List<MediaDeviceInfo>> Function()? enumerate;

  /// Makes each connection to another person: WebRTC's own, or a test's.
  @visibleForTesting
  static Future<RTCPeerConnection> Function(Map<String, dynamic> configuration)? connect;

  /// How the sound devices are listed, chosen and opened: WebRTC's own, or a test's.
  @visibleForTesting
  static SoundDevices sound = const SoundDevices();

  /// The kind of computer or phone the device rules below are for: this one, or the one a test says.
  @visibleForTesting
  static String? platformForTest;

  static String get _os =>
      platformForTest ??
      (kIsWeb
          ? 'web'
          : PlatformInfo.isMacOS
              ? 'macos'
              : PlatformInfo.isWindows
                  ? 'windows'
                  : PlatformInfo.isLinux
                      ? 'linux'
                      : PlatformInfo.isAndroid
                          ? 'android'
                          : PlatformInfo.isIOS
                              ? 'ios'
                              : 'other');

  /// Windows' WebRTC (flutter_webrtc's common/cpp) takes the microphone from `optional: [{sourceId}]` and reads
  /// `deviceId` as the speaker; the Mac's and the phones' take `deviceId` as the microphone. Asked as `deviceId` on
  /// Windows, every choice of microphone was the system's first (Matt, 2026-11-21: "the device picker is not working
  /// in windows").
  static bool get _sourceIds => _os == 'windows' || _os == 'linux';

  /// The microphone and the speaker this call has now, as worked out from the settings and the devices there are
  /// ([_useInput], [_useOutput]): empty for the system's own.
  String _input = '', _output = '';

  /// The speaker the call's sound goes to, for what is played beside WebRTC (lib/voice/music_sink.dart): empty for the
  /// system's own.
  final ValueNotifier<String> speaker = ValueNotifier('');

  /// Whether the microphone or the speaker chosen is not connected, so the system's own is used in its place.
  bool inputMissing = false, outputMissing = false;

  Map<String, Object> _audioAsked(String input, String output) => {
        if (input.isNotEmpty && !_sourceIds) 'deviceId': input,
        if (input.isNotEmpty && _sourceIds)
          'optional': [
            {'sourceId': input},
          ],
        if (output.isNotEmpty && _sourceIds) 'deviceId': output,
        'echoCancellation': settings.useEcho,
        // WebRTC's own only where it is the one used: RNNoise and DeepFilterNet run after capture (VoiceFx).
        'noiseSuppression': settings.noiseOn(VoiceFx.available) == NoiseMode.webrtc,
        'autoGainControl': settings.useGain,
        // Music mode keeps the high-pass filter off too: the microphone as it is.
        if (settings.music) 'googHighpassFilter': false,
        'channelCount': settings.sendStereo ? 2 : 1,
        'sampleRate': 48000,
      };

  /// The devices there are of [kind] (`audioinput`, `audiooutput`), by the system's names for them.
  static Future<List<MediaDeviceInfo>> devices(String kind) async {
    try {
      final all = await (enumerate ?? sound.list)();
      return [for (final d in all) if (d.kind == kind) d];
    } catch (_) {
      return const [];
    }
  }

  /// The id the system's own device has in [there], where choosing it by id is how to go back to it: the Mac lists it
  /// as "default" (the one that follows System Settings); Windows' and Linux's WebRTC open the first listed when
  /// asked for none, so going back is choosing that one. Empty where there is nothing to choose.
  static String _systemOwn(List<MediaDeviceInfo> there) {
    switch (_os) {
      case 'macos':
        return there.any((d) => d.deviceId == 'default') ? 'default' : '';
      case 'windows':
      case 'linux':
        return there.firstOrNull?.deviceId ?? '';
      default:
        return '';
    }
  }

  /// An Android microphone was chosen in this app since it started: going back to the system's own then chooses the
  /// phone's built-in one, as WebRTC keeps a chosen microphone until told another.
  static bool _androidChose = false;

  /// Works out the microphone from the settings and the devices there are now, and tells WebRTC: the one chosen, else
  /// (not connected, or none chosen) the system's own. Returns its id, empty for the system's own.
  Future<String> _useInput() async {
    final there = await devices('audioinput');
    final c = DeviceChoice.resolve(settings.input, settings.inputName, there);
    inputMissing = c.missing;
    _input = c.id;
    var pick = c.id;
    if (pick.isEmpty) {
      pick = _systemOwn(there);
      if (_os == 'android' && _androidChose) pick = there.where((d) => d.deviceId.startsWith('microphone-')).firstOrNull?.deviceId ?? '';
    }
    // The phones' and the computers' WebRTC hold one microphone for every track: chosen there, not only asked for by
    // the track (Android reads nothing of a track's deviceId; the Mac's finds the device only once WebRTC's sound is
    // started, SoundDevices.ready). A browser takes the track's own.
    if (pick.isNotEmpty && const {'macos', 'windows', 'linux', 'android'}.contains(_os)) {
      try {
        await sound.selectInput(pick);
        if (_os == 'android' && c.id.isNotEmpty) _androidChose = true;
      } catch (e) {
        debugPrint('rtc: microphone $pick not chosen: $e');
      }
    }
    return _input;
  }

  /// The same for the speaker: the one chosen, else the system's own. On a phone the system's own is the loudspeaker.
  Future<String> _useOutput() async {
    final there = await devices('audiooutput');
    final c = DeviceChoice.resolve(settings.output, settings.outputName, there);
    outputMissing = c.missing;
    _output = c.id;
    if (!_sourceIds) speaker.value = c.id;
    // A browser plays what arrives through the page's own elements (call_sound.dart), sent to the speaker chosen
    // where it lets a page choose.
    if (CallSound.playsItself) {
      await _out.output(c.id);
      return _output;
    }
    if (_os == 'android' && c.id.isEmpty) {
      await sound.speakerphone(true).catchError((_) {});
      return _output;
    }
    final pick = c.id.isNotEmpty ? c.id : _systemOwn(there);
    // Windows and Linux open the first listed for the system's own, whichever Windows itself plays to.
    if (_sourceIds) speaker.value = pick;
    if (pick.isNotEmpty && _os != 'web') {
      try {
        await sound.selectOutput(pick);
      } catch (e) {
        debugPrint('rtc: speaker $pick not chosen: $e');
      }
    }
    return _output;
  }

  /// Takes sound from another microphone, in the call as it goes: the new one's track in every connection's place.
  /// [name] is the system's name for it, to find it again by.
  Future<void> setInput(String deviceId, {String name = ''}) async {
    settings = settings.copyWith(input: deviceId, inputName: deviceId.isEmpty ? '' : name);
    final old = _mic;
    if (old == null) return;
    final input = await _useInput();
    final fresh = await sound.open({'audio': _audioAsked(input, _output), 'video': false});
    final track = fresh.getAudioTracks().first;
    track.enabled = old.getAudioTracks().firstOrNull?.enabled ?? true;
    _mic = fresh;
    for (final p in _peers.values) {
      final made = p._pc;
      if (made == null) continue;
      for (final s in await (await made).getSenders()) {
        if (s.track?.kind == 'audio') await s.replaceTrack(track);
      }
    }
    final meter = _meter;
    if (meter != null) {
      for (final s in await meter.getSenders()) {
        if (s.track?.kind == 'audio') await s.replaceTrack(track);
      }
    }
    for (final t in old.getTracks()) {
      await t.stop();
    }
    await old.dispose();
    // The microphone's processing (noise removal, the gain, the voice changer's effect) given to the new one too.
    await VoiceFx.apply(settings);
  }

  /// Plays the call through another speaker or headset, in the call as it goes. [name] as for [setInput].
  Future<void> setOutput(String deviceId, {String name = ''}) async {
    settings = settings.copyWith(output: deviceId, outputName: deviceId.isEmpty ? '' : name);
    await _useOutput();
  }

  @override
  Future<void> start() async {
    // The native processing first: what it can run decides whether WebRTC's own noise suppression is asked for.
    await VoiceFx.apply(settings);
    // The devices first: the chosen microphone is opened, or the system's own where it is not connected.
    // Windows' and Linux's WebRTC take the speaker with the microphone ([_audioAsked]), so it is worked out first there;
    // elsewhere after, as Android's sound routing starts with the microphone.
    if (_mic == null) {
      final input = await _useInput();
      if (_sourceIds) await _useOutput();
      _mic = await sound.open({'audio': _audioAsked(input, _output), 'video': false});
    }
    // And again with the microphone open: the native hook is there only once WebRTC is (android VoiceFx.kt).
    unawaited(VoiceFx.apply(settings));
    if (!_sourceIds) await _useOutput();
    // A light test: the microphone by itself, measured by the native half ([light]).
    if (light && _peers.isEmpty && VoiceFx.levelSupported) {
      try {
        await NativeAudioManagement.startLocalRecording();
        _local = true;
      } catch (_) {
        _local = false;
      }
    }
    // How loud each voice is is read only while a face can be seen rippling ([_seenChanged]), and by the native half
    // where it taps each voice itself ([_syncTaps]).
    if (!_on) {
      _on = true;
      micLive.value = false;
      AppSeen.follow();
      AppSeen.now.addListener(_seenChanged);
      sounds.addListener(_syncTaps);
    }
    unawaited(_syncTaps());
    if (!AppSeen.now.value) return;
    // Alone, the microphone is measured through the meter (_openMeter); with others, through their connections.
    if (_peers.isEmpty && !_local) await _openMeter();
    _levelTimer ??= Timer.periodic(levelEvery, (_) => _readLevels());
  }

  @override
  Future<void> stop() async {
    if (_on) {
      _on = false;
      AppSeen.now.removeListener(_seenChanged);
      sounds.removeListener(_syncTaps);
    }
    _linksReadAt = null;
    _levelTimer?.cancel();
    _levelTimer = null;
    if (_local) {
      _local = false;
      await NativeAudioManagement.stopLocalRecording().catchError((_) {});
    }
    levels.value = const {};
    links.value = const {};
    final meter = _meter, meterSink = _meterSink;
    _meter = null;
    _meterSink = null;
    _sinkTracks.clear();
    _sinkQuiet.clear();
    if (meter != null) await closeConnection(meter);
    if (meterSink != null) await closeConnection(meterSink);
    _energy = _energyTime = null;
    for (final p in _peers.values.toList()) {
      await p.close();
    }
    _peers.clear();
    _out.stopAll();
    remote.value = const {};
    sounds.value = const {};
    // The native half lets go of every voice it was tapping.
    unawaited(_syncTaps());
    for (final s in [_mic, _cam, _screen]) {
      for (final t in s?.getTracks() ?? const <MediaStreamTrack>[]) {
        await t.stop();
      }
      await s?.dispose();
    }
    _mic = null;
    _cam = null;
    localVideo.value = null;
    if (_screen != null && !kIsWeb && PlatformInfo.isAndroid) unawaited(screenService?.call(false));
    _screen = null;
    _screenHeight = null;
    localScreen.value = null;
  }

  @override
  set muted(bool on) {
    for (final t in _mic?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = !on;
    }
  }

  @override
  set deafened(bool on) {
    _deaf = on;
    _peers.keys.forEach(_apply);
  }

  /// Settings changed while in the call: how loud others are and the microphone's processing at once; the rest
  /// from the next call.
  Future<void> applyLive(VoiceSettings fresh) async {
    settings = fresh.copyWith(input: settings.input, output: settings.output, inputName: settings.inputName, outputName: settings.outputName, camera: settings.camera, cameraName: settings.cameraName);
    _peers.keys.forEach(_apply);
    await VoiceFx.apply(settings);
  }

  MediaStreamTrack? get _camTrack => _cam?.getVideoTracks().firstOrNull;

  /// What this device's picture is now: the screen while it is shared, else the camera while it is on.
  MediaStreamTrack? get _picture => _screen?.getVideoTracks().firstOrNull ?? _camTrack;

  /// Shown the screen of whoever shares it, sent at 1080 lines at most, holding its sharpness over its frame rate:
  /// words on a screen matter more than smooth movement.
  bool get sharing => _screen != null;

  /// A shared screen's bitrate: what the camera would get with this many in the call, but never under 2.5 Mb/s, as
  /// small words blur first.
  @visibleForTesting
  static int screenBitrate(int camera) => math.max(camera, 2500000);

  /// How much a shared screen [height] lines tall is scaled down: to 1080 lines at most, never up.
  @visibleForTesting
  static double screenScale(double? height) => height == null || height <= 1080 ? 1.0 : height / 1080;

  @override
  bool get screenSupported => !kIsWeb && (PlatformInfo.isAndroid || PlatformInfo.isMacOS || PlatformInfo.isWindows || PlatformInfo.isLinux);

  /// What the system's capturer has listed, by id, kept between askings: flutter_webrtc's first answer has the
  /// names only, and each picture, and any screen or window found later, comes afterwards as an event that changes
  /// these same objects (its lib/src/native/desktop_capturer_impl.dart). The capturer is one for the whole app, so
  /// these are too.
  static final Map<String, DesktopCapturerSource> _listed = {};
  static DateTime? _listedAt;
  static StreamSubscription<DesktopCapturerSource>? _listedMore, _listedFewer;

  /// The list is started over when it was last asked for longer ago than this (the picker asks every two seconds
  /// while it is open, lib/ui/screen_share.dart); sooner, the capturer is only told to look again, which keeps the
  /// pictures it already has.
  static const _listedFor = Duration(seconds: 6);

  @override
  Future<List<ScreenSource>> screenSources() async {
    if (kIsWeb || PlatformInfo.isAndroid || PlatformInfo.isIOS) return const [];
    // The Mac asks for Screen Recording once (System Settings › Privacy); without it every picture is blank.
    if (PlatformInfo.isMacOS) await Helper.requestCapturePermission().catchError((_) => false);
    try {
      const types = [SourceType.Screen, SourceType.Window];
      // Matt, 2026-11-23: "screen sharing on mac and pc doesn't show anything to select". What arrives after the
      // first answer is kept, so the picker's next asking has it.
      _listedMore ??= desktopCapturer.onAdded.stream.listen((s) => _listed[s.id] = s);
      _listedFewer ??= desktopCapturer.onRemoved.stream.listen((s) => _listed.remove(s.id));
      final now = DateTime.now();
      final recent = _listedAt != null && now.difference(_listedAt!) < _listedFor;
      _listedAt = now;
      if (recent) {
        await desktopCapturer.updateSources(types: types);
      } else {
        final found = await desktopCapturer.getSources(types: types, thumbnailSize: ThumbnailSize(320, 200));
        _listed
          ..clear()
          ..addAll({for (final s in found) s.id: s});
      }
      return [
        for (final s in _listed.values)
          ScreenSource(id: s.id, name: s.name.isEmpty ? (s.type == SourceType.Screen ? 'Screen' : 'Window') : s.name, window: s.type == SourceType.Window, thumbnail: s.thumbnail),
      ];
    } catch (e) {
      debugPrint('rtc: no screens to share: $e');
      // The next asking starts over.
      _listedAt = null;
      return const [];
    }
  }

  @override
  Future<bool> setScreen(bool on, {String? source, void Function()? onEnded}) async {
    if (!on) {
      await _stopScreen();
      return true;
    }
    if (!screenSupported) return false;
    MediaStream stream;
    try {
      if (PlatformInfo.isAndroid) {
        // The system's question first, then the service, then the capture (CallService.kt says why).
        final yes = await Helper.requestCapturePermission();
        if (!yes) return false;
        await screenService?.call(true);
        stream = await navigator.mediaDevices.getDisplayMedia({'video': true, 'audio': false});
      } else {
        if (source == null) return false;
        stream = await navigator.mediaDevices.getDisplayMedia({
          'video': {
            'deviceId': {'exact': source},
            'mandatory': {'frameRate': 30.0},
          },
          // A PC's sound comes with its screen where it is asked for (see [screenWithSound]).
          'audio': screenWithSound && PlatformInfo.isWindows,
        });
      }
    } catch (e) {
      debugPrint('rtc: the screen was not shared: $e');
      if (PlatformInfo.isAndroid) await screenService?.call(false);
      return false;
    }
    final track = stream.getVideoTracks().firstOrNull;
    if (track == null) {
      await stream.dispose();
      if (PlatformInfo.isAndroid) await screenService?.call(false);
      return false;
    }
    // Another share in this one's place: the old one goes, and its sound's connections with it.
    final old = _screen;
    final oldSound = _screenSound;
    _screenSound = null;
    await oldSound?.end().catchError((_) {});
    _screen = stream;
    if (screenWithSound) {
      if (PlatformInfo.isWindows) {
        final heard = stream.getAudioTracks().firstOrNull;
        if (heard != null) _screenSound = TrackShareSound(heard);
      } else if (PlatformInfo.isMacOS) {
        _screenSound = await MacShareSound.begin();
        // Stopped, or another share begun, while the Mac was asked.
        if (!identical(_screen, stream)) {
          await _screenSound?.end().catchError((_) {});
          _screenSound = null;
        }
      }
    }
    localScreen.value = stream;
    _screenHeight = null;
    try {
      final h = track.getSettings()['height'];
      if (h is num && h > 0) _screenHeight = h.toDouble();
    } catch (_) {}
    // Ended from outside the app (the system's own "Stop sharing", the shared window closed): stopped here too.
    track.onEnded = () {
      if (!identical(_screen, stream)) return;
      unawaited(_stopScreen().then((_) => onEnded?.call()));
    };
    for (final p in _peers.values) {
      await p.showCamera(_picture);
    }
    if (old != null) await _dispose(old);
    return true;
  }

  /// Stops sharing the screen and lets its capture go.
  Future<void> _stopScreen() async {
    final was = _screen;
    if (was == null) return;
    _screen = null;
    _screenHeight = null;
    final sound = _screenSound;
    _screenSound = null;
    unawaited(sound?.end().catchError((_) {}));
    localScreen.value = null;
    // The camera back in its place where video is on; else no picture.
    for (final p in _peers.values) {
      await p.showCamera(_picture);
    }
    // As with the camera: the renderer lets go first (GMFB-5).
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await _dispose(was);
    if (!kIsWeb && PlatformInfo.isAndroid) await screenService?.call(false);
  }

  /// Stops every track of a stream made here (the camera's or microphone's light goes out), then lets it go.
  static Future<void> _dispose(MediaStream s) async {
    for (final t in s.getTracks()) {
      await t.stop();
    }
    await s.dispose();
  }

  /// The camera on the back of the phone is the one in use, or the one video opens with next (GMFB-57).
  bool _back = false;
  bool _flipping = false;

  @override
  bool get backCamera => _back;

  /// A phone has two cameras to change between; a computer's are chosen in Settings › Voice.
  @override
  bool get canFlipCamera => !kIsWeb && (PlatformInfo.isAndroid || PlatformInfo.isIOS);

  /// Changes between the front and the back camera (GMFB-57). The capture changes under the same track, so every
  /// connection and the preview keep the track they have: nothing is replaced or worked out again. With video off
  /// only the choice changes, for when it is turned on.
  @override
  Future<void> flipCamera() async {
    if (!canFlipCamera || _flipping) return;
    final track = _camTrack;
    if (track == null) {
      _back = !_back;
      return;
    }
    _flipping = true;
    try {
      await Helper.switchCamera(track);
      _back = !_back;
    } finally {
      _flipping = false;
    }
  }

  /// Whether a camera is chosen by name here (GMFB-68): a computer or a browser. A phone has Flip camera instead.
  static bool get choosesCamera => _os != 'android' && _os != 'ios';

  /// The camera chosen in Settings is not connected, so the system's own is used in its place (GMFB-68).
  bool cameraMissing = false;
  bool _changingCamera = false;

  /// The camera to open (GMFB-68, Matt: "There is no way to switch or select a video device in the app or actively
  /// during a call"): the one chosen in Settings › Voice and video where it is connected, else the system's own
  /// (empty). A phone's are its front and its back, changed between in the call ([flipCamera]), so none is chosen there.
  Future<String> _useCamera() async {
    if (!choosesCamera || settings.camera.isEmpty) {
      cameraMissing = false;
      return '';
    }
    final c = DeviceChoice.resolve(settings.camera, settings.cameraName, await devices('videoinput'));
    cameraMissing = c.missing;
    return c.id;
  }

  /// What the camera [camera] is asked for: the picture's size, and which camera. Windows' and Linux's WebRTC take the
  /// camera from `optional: [{sourceId}]` as they do the microphone ([_sourceIds]); the Mac's and a browser's from
  /// `deviceId`. With none chosen, the one facing the person, or a phone's back one once flipped to.
  Map<String, Object> _videoAsked(String camera) => {
        'width': settings.videoSize.width,
        'height': settings.videoSize.height,
        'frameRate': 30,
        if (camera.isEmpty) 'facingMode': _back ? 'environment' : 'user',
        if (camera.isNotEmpty && !_sourceIds) 'deviceId': camera,
        if (camera.isNotEmpty && _sourceIds)
          'optional': [
            {'sourceId': camera},
          ],
      };

  Future<MediaStream> _openCamera() async => sound.open({'audio': false, 'video': _videoAsked(await _useCamera())});

  /// Films with another camera (GMFB-68), in the call as it goes: the new one's picture in the old one's place in
  /// every connection and in this device's own tile. With video off only the choice changes, for when it is turned
  /// on. [name] is the system's name for it, to find it again by. A camera that will not open leaves the picture as
  /// it was where it can.
  Future<void> setCamera(String deviceId, {String name = ''}) async {
    settings = settings.copyWith(camera: deviceId, cameraName: deviceId.isEmpty ? '' : name);
    final old = _cam;
    if (old == null || _changingCamera) return;
    _changingCamera = true;
    try {
      MediaStream fresh;
      var let = false;
      try {
        fresh = await _openCamera();
      } catch (_) {
        // Some cameras open once only (Windows, when the one chosen is the one already filming): the old picture is
        // let go first, then it is asked for again.
        if (!identical(_cam, old)) return;
        await _dispose(old);
        let = true;
        fresh = await _openCamera();
      }
      // Video turned off while the camera opened: nothing to put it in.
      if (!identical(_cam, old)) {
        await _dispose(fresh);
        return;
      }
      _cam = fresh;
      localVideo.value = fresh;
      for (final p in _peers.values) {
        await p.showCamera(_picture);
      }
      if (!let) {
        // As when video is turned off: the tile lets go of the old picture's renderer first (GMFB-5).
        await Future<void>.delayed(const Duration(milliseconds: 120));
        await _dispose(old);
      }
    } finally {
      _changingCamera = false;
    }
  }

  @override
  Future<void> setVideo(bool on) async {
    if (on && _cam == null) {
      _cam = await _openCamera();
      localVideo.value = _cam;
    } else if (!on && _cam != null) {
      final cam = _cam!;
      _cam = null;
      localVideo.value = null;
      // The shared screen stays where there is one.
      for (final p in _peers.values) {
        await p.showCamera(_picture);
      }
      // Let the screen drop its renderer of this camera before the camera goes (GMFB-5: a renderer still holding a
      // disposed stream kept its last frame, on the Mac, in whichever tile it had moved to).
      await Future<void>.delayed(const Duration(milliseconds: 120));
      for (final t in cam.getTracks()) {
        await t.stop();
      }
      await cam.dispose();
      return;
    }
    for (final p in _peers.values) {
      await p.showCamera(_picture);
    }
  }

  /// How the connection to [id] stands, for the call to mend one that is not through (VoiceSession._mendAll).
  @override
  bool? linkUp(String id) => switch (links.value[id]) {
        PeerLink.connected || PeerLink.poor => true,
        PeerLink.connecting || PeerLink.reconnecting => false,
        _ => null,
      };

  @override
  VoicePeer peer(String id, {required void Function(Map<String, dynamic> candidate) onCandidate}) => peerWith(id, onCandidate: onCandidate, onFailed: () {});

  @override
  VoicePeer peerWith(String id, {required void Function(Map<String, dynamic> candidate) onCandidate, required void Function() onFailed, bool relayOnly = false}) {
    final had = _peers[id];
    if (had != null) return had;
    final made = _peers[id] = _RtcPeer(this, id, onCandidate, onFailed: onFailed, relayOnly: relayOnly);
    _link(id, PeerLink.connecting);
    _retune();
    return made;
  }

  /// Someone came or went: every copy of the picture is sized again for how many there are now.
  void _retune() {
    for (final p in _peers.values) {
      final made = p._pc;
      if (made != null) unawaited(made.then(p._highest).catchError((_) {}));
    }
  }

  /// [id]'s picture arrived: the stream their tile draws.
  void _heard(String id, MediaStream view) => remote.value = {...remote.value, id: view};

  /// [id]'s connection failed or closed: forgotten, and the others' pictures sized again.
  void _gone(String id) {
    if (_peers.remove(id) != null) _retune();
    remote.value = {...remote.value}..remove(id);
    _out.stop(id);
    if (sounds.value.containsKey(id)) sounds.value = {...sounds.value}..remove(id);
    // A failure is left showing until a new try begins ([peerWith]); anything else goes with the connection.
    if (links.value[id] != PeerLink.failed) _link(id, null);
  }
}

/// The WebRTC connection to one other person in the call, made when first needed.
class _RtcPeer implements VoicePeer {
  _RtcPeer(this.media, this.id, this.onCandidate, {required this.onFailed, this.relayOnly = false});
  final RtcMedia media;
  final String id;
  final void Function(Map<String, dynamic> candidate) onCandidate;

  /// No way through was found (VoiceSession starts over through the relay alone).
  final void Function() onFailed;

  /// Through the relay's TURN server alone: the second try, after a connection that tried every path failed.
  final bool relayOnly;
  Future<RTCPeerConnection>? _pc;
  /// Ways to connect that came before the other side's description was set; added once it is ([_settled]).
  final List<RTCIceCandidate> _early = [];
  bool _described = false;

  /// The sound tracks this connection receives ([RtcMedia._apply] sets their volume).
  final List<MediaStreamTrack> _sounds = [];

  /// A stream made on this device holding the picture this connection receives, which their tile draws. The track
  /// is put in one made here, never in the stream it arrived with: flutter_webrtc adds tracks only to streams made on
  /// the device (Android, the Mac and Windows all answer "stream is null" for a received one), and the picture
  /// arrives in no stream at all (its sender names none), so it was added to the sound's received stream, refused,
  /// and no tile ever drew another member's camera (Matt, 2026-11-21: "Video is not working on both ends it only
  /// shows our local video").
  MediaStream? _view;

  /// Received tracks are taken one at a time: two at once each made a stream of their own.
  Future<void> _taking = Future.value();

  /// Not connected this long after the descriptions are set: no way through ([onFailed]), as WebRTC itself can take
  /// half a minute or more to say, or never does on some networks.
  static const connectWithin = Duration(seconds: 15);
  Timer? _connectTimer;
  bool _connected = false, _failedSaid = false;

  /// Says, once, that no way through was found; never after it has connected.
  void _fail() {
    if (_failedSaid || _connected) return;
    _failedSaid = true;
    if (identical(media._peers[id], this)) media._link(id, PeerLink.failed);
    _connectTimer?.cancel();
    onFailed();
  }

  /// Starts the wait of [connectWithin], once.
  void _watchConnect() {
    if (_connected || _connectTimer != null) return;
    _connectTimer = Timer(connectWithin, _fail);
  }

  /// A track arrived: a sound is kept for its volume; a picture takes the place of the one before in [_view].
  Future<void> _took(RTCTrackEvent e) async {
    final track = e.track;
    if (track.kind == 'audio') {
      if (!_sounds.any((t) => t.id == track.id)) _sounds.add(track);
      if (identical(media._peers[id], this)) {
        media._out.play(id, track);
        media._apply(id);
        // Said for a recording to tap (GMFB-52), with this connection's mark: one made again says a new one.
        final sound = track.id;
        if (sound != null) media.sounds.value = {...media.sounds.value, id: (track: sound, link: identityHashCode(this))};
      }
      return;
    }
    if (track.kind != 'video') return;
    var view = _view;
    if (view != null && view.getVideoTracks().any((t) => t.id == track.id)) return;
    if (view != null) {
      for (final t in view.getVideoTracks().toList()) {
        await view.removeTrack(t).catchError((_) {});
      }
    } else {
      view = _view = await createLocalMediaStream('ghost-view-$id-${identityHashCode(this)}');
    }
    await view.addTrack(track);
    // Not for a connection made in this one's place since (the same person in from another device).
    if (identical(media._peers[id], this) && identical(_view, view)) media._heard(id, view);
  }

  Future<RTCPeerConnection> get pc => _pc ??= _make();

  /// Makes the connection and wires what it finds to the session (candidates) and to [media] (their stream, their
  /// going).
  Future<RTCPeerConnection> _make() async {
    final pc = await (RtcMedia.connect ?? createPeerConnection)({'iceServers': media.iceServers, 'sdpSemantics': 'unified-plan', if (relayOnly) 'iceTransportPolicy': 'relay'});
    pc.onIceCandidate = (c) {
      if (c.candidate != null) onCandidate({'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex});
    };
    pc.onTrack = (e) {
      RtcMedia._noteConnection(pc, e.track);
      _taking = _taking.then((_) => _took(e)).catchError((Object err) => debugPrint('rtc: track from $id not shown: $err'));
    };
    pc.onConnectionState = (s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _connected = true;
        _connectTimer?.cancel();
      }
      if (identical(media._peers[id], this)) {
        final link = switch (s) {
          RTCPeerConnectionState.RTCPeerConnectionStateConnected => PeerLink.connected,
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected => PeerLink.reconnecting,
          RTCPeerConnectionState.RTCPeerConnectionStateFailed => PeerLink.failed,
          RTCPeerConnectionState.RTCPeerConnectionStateNew || RTCPeerConnectionState.RTCPeerConnectionStateConnecting => PeerLink.connecting,
          _ => null,
        };
        if (link != null) media._link(id, link);
      }
      final failed = s == RTCPeerConnectionState.RTCPeerConnectionStateFailed;
      if ((failed || s == RTCPeerConnectionState.RTCPeerConnectionStateClosed) && identical(media._peers[id], this)) {
        // Said before it is let go of, so the side that offered can start over (VoiceSession._failed).
        if (failed) _fail();
        media._gone(id);
      }
    };
    return pc;
  }

  /// One sound and one picture both ways, for the side that offers.
  Future<void> _addOwn(RTCPeerConnection pc) async {
    final mic = media._mic!.getAudioTracks().first;
    final sound = await pc.addTransceiver(track: mic, kind: RTCRtpMediaType.RTCRtpMediaTypeAudio, init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv, streams: [media._mic!]));
    RtcMedia._noteConnection(pc, sound.sender);
    await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv, sendEncodings: [RTCRtpEncoding(maxBitrate: media.settings.sendTo(media._peers.length, videoFor(media._peers.length)).bitrate, maxFramerate: 30, scaleResolutionDownBy: media.settings.sendTo(media._peers.length, videoFor(media._peers.length)).scale)]),
    );
    if (media._picture != null) await showCamera(media._picture);
  }

  /// The side that answers takes the offer's sound and picture, and puts its own in them.
  Future<void> _fillOwn(RTCPeerConnection pc) async {
    for (final t in await pc.getTransceivers()) {
      final kind = t.receiver.track?.kind;
      if (kind == 'audio') {
        await t.sender.replaceTrack(media._mic!.getAudioTracks().first);
        await t.setDirection(TransceiverDirection.SendRecv);
      } else if (kind == 'video') {
        await t.sender.replaceTrack(media._picture);
        await t.setDirection(TransceiverDirection.SendRecv);
      }
    }
  }

  /// Sound at the rate Settings › Voice chose ([audioBitrate]); the picture as big as the number of others allows ([videoFor]).
  Future<void> _highest(RTCPeerConnection pc) async {
    final v = media.settings.sendTo(media._peers.length, videoFor(media._peers.length));
    for (final s in await pc.getSenders()) {
      final kind = s.track?.kind;
      final p = s.parameters;
      final encodings = p.encodings;
      if (encodings == null || encodings.isEmpty) continue;
      final screen = kind == 'video' && media.sharing;
      for (final e in encodings) {
        e.maxBitrate = kind == 'audio' ? media.audioBitrate : (screen ? RtcMedia.screenBitrate(v.bitrate) : v.bitrate);
        if (kind == 'video') e.scaleResolutionDownBy = screen ? RtcMedia.screenScale(media._screenHeight) : v.scale;
      }
      // A shared screen keeps its sharpness and gives up frames when the way is narrow; a camera balances the two.
      if (kind == 'video') p.degradationPreference = screen ? RTCDegradationPreference.MAINTAIN_RESOLUTION : RTCDegradationPreference.BALANCED;
      try {
        await s.setParameters(p);
      } catch (_) {}
    }
  }

  /// Sends [track] as this device's picture on this connection; null stops sending one.
  Future<void> showCamera(MediaStreamTrack? track) async {
    final c = await pc;
    for (final t in await c.getTransceivers()) {
      if (t.receiver.track?.kind == 'video' || t.sender.track?.kind == 'video') await t.sender.replaceTrack(track);
    }
    await _highest(c);
  }

  @override
  Future<String> makeOffer() async {
    final c = await pc;
    await _addOwn(c);
    final offer = await c.createOffer();
    final sdp = highestOpus(offer.sdp ?? '', kbps: media.settings.sendKbps, stereo: media.settings.sendStereo);
    await c.setLocalDescription(RTCSessionDescription(sdp, 'offer'));
    await _highest(c);
    return sdp;
  }

  @override
  Future<String> takeOffer(String sdp) async {
    final c = await pc;
    await c.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    await _settled(c);
    await _fillOwn(c);
    final answer = await c.createAnswer();
    final mine = highestOpus(answer.sdp ?? '', kbps: media.settings.sendKbps, stereo: media.settings.sendStereo);
    await c.setLocalDescription(RTCSessionDescription(mine, 'answer'));
    await _highest(c);
    return mine;
  }

  @override
  Future<void> takeAnswer(String sdp) async {
    final c = await pc;
    await c.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    await _settled(c);
  }

  /// The other side's description is set: the candidates held back until now are added.
  Future<void> _settled(RTCPeerConnection c) async {
    _described = true;
    _watchConnect();
    for (final cand in _early) {
      // One that was another connection's (sent before it was let go) is no reason to fail this one.
      try {
        await c.addCandidate(cand);
      } catch (_) {}
    }
    _early.clear();
  }

  @override
  Future<void> addCandidate(Map<String, dynamic> m) async {
    final cand = RTCIceCandidate(m['candidate'] as String?, m['sdpMid'] as String?, (m['sdpMLineIndex'] as num?)?.toInt());
    if (!_described) {
      _early.add(cand);
      return;
    }
    await (await pc).addCandidate(cand);
  }

  @override
  Future<void> close() async {
    _connectTimer?.cancel();
    _failedSaid = true;
    final made = _pc;
    _pc = null;
    final stream = _view;
    _view = null;
    // Let go of at once, before the closing is waited for: a connection to the same id made meanwhile (their offer from
    // another device, right behind 'moved') is a new one, and this one's end must not take it away.
    if (identical(media._peers[id], this)) media._gone(id);
    if (made != null) {
      final pc = await made;
      await RtcMedia.closeConnection(pc);
      // Let go of by the platform too: it finds a received track by its id among every connection it still holds, and
      // a connection made again brings their sound under the same id, so a recording asking for it could be handed
      // this closed one's, which is silent (GMFB-52).
      await pc.dispose().catchError((_) {});
    }
    await stream?.dispose();
  }
}


/// How this device's connection to someone in a call stands (GMFB-4, @kevin: "show when users are connected to the
/// call so they and others know if they are having audio issues or if they are just not connected to the call").
enum PeerLink {
  /// Still finding a way through.
  connecting,

  /// Through, and sound goes both ways.
  connected,

  /// Through, but slow: what is said takes long to arrive, or breaks up.
  poor,

  /// Was through, and lost the way: WebRTC is trying again.
  reconnecting,

  /// No way through.
  failed;

  /// In a few words, for a person's row; null where nothing need be said.
  String? get words => switch (this) {
        PeerLink.connecting => 'Connecting…',
        PeerLink.connected => null,
        PeerLink.poor => 'Poor connection',
        PeerLink.reconnecting => 'Reconnecting…',
        PeerLink.failed => 'Can\'t connect',
      };
}

/// Which device a choice comes to among those there are now ([resolve]).
@immutable
class DeviceChoice {
  const DeviceChoice(this.id, {this.missing = false});

  /// The device to use; empty for the system's own.
  final String id;

  /// The device chosen is not connected: the system's own is used in its place.
  final bool missing;

  /// The device chosen as [id] (with the system's [name] for it when it was chosen) among [there]: by its id, else
  /// by its name where exactly one real device has it (an id that changed since: Android numbers a USB microphone
  /// afresh each time it is plugged in), else the system's own, said to be [missing]. An empty [id] is the system's
  /// own.
  static DeviceChoice resolve(String id, String name, List<MediaDeviceInfo> there) {
    if (id.isEmpty) return const DeviceChoice('');
    if (there.any((d) => d.deviceId == id)) return DeviceChoice(id);
    if (name.isNotEmpty) {
      // The Mac lists the system's own as "default", under the name of the device it is now: never taken for a real one.
      final named = [for (final d in there) if (d.label == name && d.deviceId != 'default') d];
      if (named.length == 1) return DeviceChoice(named.single.deviceId);
    }
    return const DeviceChoice('', missing: true);
  }
}

/// How sound devices are listed, chosen and opened, through flutter_webrtc: one place, so a test can stand in for it
/// (RtcMedia.sound) and see which device each step asked for.
class SoundDevices {
  const SoundDevices();

  static Future<void>? _ready;

  /// Once in the app's life, on a computer: WebRTC's sound started, so it knows every device. Until a first connection
  /// is made, the Mac's lists only "default" for the microphone and the speaker, and choosing any other answers
  /// "deviceId not found!": every device chosen in Settings was dropped at the start of a call, which took the
  /// system's own (Matt, 2026-11-23: "switching input and output devices doesn't work we have to switch them on the
  /// physical settings on the operating system for them to change, it seems to only use the default device"). One
  /// connection made and closed at once, a few milliseconds.
  Future<void> ready() => _ready ??= () async {
        if (kIsWeb || !(PlatformInfo.isMacOS || PlatformInfo.isWindows || PlatformInfo.isLinux)) return;
        try {
          final pc = await createPeerConnection({});
          await pc.close();
        } catch (_) {}
      }();

  /// Every device the system has, sound and cameras.
  Future<List<MediaDeviceInfo>> list() async {
    await ready();
    return navigator.mediaDevices.enumerateDevices();
  }

  Future<MediaStream> open(Map<String, dynamic> constraints) => navigator.mediaDevices.getUserMedia(constraints);

  Future<void> selectInput(String id) async {
    await ready();
    await Helper.selectAudioInput(id);
  }

  Future<void> selectOutput(String id) async {
    await ready();
    await Helper.selectAudioOutput(id);
  }

  Future<void> speakerphone(bool on) => Helper.setSpeakerphoneOn(on);
}
