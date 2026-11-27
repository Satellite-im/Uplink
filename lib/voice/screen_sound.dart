/// The computer's sound with a shared screen (GMFB-63, Matt, 2026-11-25: "Screen shares should include audio controls
/// but there are none and users can't hear any audio from the share"; GMFB-27: "choose a screen or window, with audio
/// where the OS allows").
///
/// - **Whoever shares** a screen or a window from a PC or a Mac may send what the computer plays with it: everything
///   but this app's own sound (so nobody hears the call back), or the one app whose window is shared. Their 'me' says
///   so ('sa' beside 's'). The sound is taken by the media ([ShareSoundSource], lib/voice/rtc.dart): on a PC what
///   flutter_webrtc's own capture gives with the screen, on a Mac a Core Audio tap (macos/Runner/ScreenSound.swift).
/// - **It goes** from their device to each viewer's over a connection of its own, asked for by the viewer and made by
///   the sharer, as the music played to a call does (spotify.dart, whose listener's connection this uses): stereo
///   Opus, beside the call's connections and no part of them. The picture goes in the camera's place on the call's
///   own connection, which has one sound and is never worked out again; a second sound on it is something a build
///   from before this would not know what to do with. So the microphone, mute, recordings, captions and Scribe know
///   nothing of a share's sound.
/// - **Whoever views** hears it with a loudness of its own on their device ([volume]; at 0 it is not asked for at
///   all), and deafened hears none of it.
///
/// What is said is in the call's room, sealed as everything said there is ('ss': ask, offer, ans, ice). A build from
/// before this ignores it and shows the picture as it always did.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../app_state.dart';
import '../net/crypto.dart';
import 'channels.dart';
import 'rtc.dart';
import 'spotify_link.dart';
import 'voice.dart';

/// How a share's sound is sent: Opus in stereo, with none of its bits spent on saying things twice.
const shareSoundKbps = 256;
String shareSoundOpus(String sdp) => highestOpus(sdp, kbps: shareSoundKbps, fec: false);

/// A sound that flutter_webrtc made a track of (a PC's, with its screen): each viewer gets a connection that only
/// sends it. Nothing native of this app's: the track is the plugin's own, and so are the connections.
class TrackShareSound implements ShareSoundSource {
  TrackShareSound(this.track);
  final MediaStreamTrack track;

  @override
  void Function(String id, Map<String, dynamic> candidate)? onCandidate;
  @override
  void Function(String id, String state)? onState;

  final Map<String, RTCPeerConnection> _links = {};
  bool _ended = false;

  @override
  Future<String?> offer(String id, {required List<Map<String, Object>> servers, required bool relayOnly}) async {
    if (_ended) return null;
    await close(id);
    final pc = await RtcMedia.make({'iceServers': servers, 'sdpSemantics': 'unified-plan', if (relayOnly) 'iceTransportPolicy': 'relay'});
    // Ended while it was being made.
    if (_ended) {
      await pc.close();
      return null;
    }
    _links[id] = pc;
    pc.onIceCandidate = (c) {
      if (c.candidate != null && identical(_links[id], pc)) onCandidate?.call(id, {'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex});
    };
    pc.onConnectionState = (s) {
      if (!identical(_links[id], pc)) return;
      onState?.call(id, switch (s) {
        RTCPeerConnectionState.RTCPeerConnectionStateConnected => 'connected',
        RTCPeerConnectionState.RTCPeerConnectionStateFailed => 'failed',
        RTCPeerConnectionState.RTCPeerConnectionStateClosed => 'closed',
        _ => 'connecting',
      });
    };
    try {
      final way = await pc.addTransceiver(
        track: track,
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendOnly, streams: const [], sendEncodings: [RTCRtpEncoding(maxBitrate: shareSoundKbps * 1000)]),
      );
      RtcMedia.note(pc, way.sender);
      final made = await pc.createOffer();
      final sdp = shareSoundOpus(made.sdp ?? '');
      await pc.setLocalDescription(RTCSessionDescription(sdp, 'offer'));
      return sdp;
    } catch (e) {
      debugPrint('screen sound: no connection to $id: $e');
      await close(id);
      return null;
    }
  }

  @override
  Future<bool> answer(String id, String sdp) async {
    final pc = _links[id];
    if (pc == null) return false;
    try {
      await pc.setRemoteDescription(RTCSessionDescription(shareSoundOpus(sdp), 'answer'));
      return true;
    } catch (e) {
      debugPrint('screen sound: $id\'s answer not taken: $e');
      return false;
    }
  }

  @override
  Future<void> candidate(String id, Map<String, dynamic> c) async {
    try {
      await _links[id]?.addCandidate(RTCIceCandidate(c['candidate'] as String?, c['sdpMid'] as String?, (c['sdpMLineIndex'] as num?)?.toInt()));
    } catch (_) {}
  }

  @override
  Future<void> close(String id) async {
    final pc = _links.remove(id);
    if (pc == null) return;
    await RtcMedia.closeConnection(pc).catchError((_) {});
    await pc.dispose().catchError((_) {});
  }

  @override
  Future<void> end() async {
    _ended = true;
    for (final id in _links.keys.toList()) {
      await close(id);
    }
  }
}

/// A Mac's: its native half takes what the Mac plays (a Core Audio tap of everything but this app's own sound) and makes
/// the connections, as it does for a call's music (macos/Runner/ScreenSound.swift, the `ghost/screen_sound` channel).
/// flutter_webrtc gives a Mac no sound with a captured screen.
class MacShareSound implements ShareSoundSource {
  MacShareSound._();
  static const channel = MethodChannel('ghost/screen_sound');

  /// The one there is: what the native half says is for it.
  static MacShareSound? _now;

  /// Whether this Mac can (macOS 14.4 or later).
  static Future<bool> able() async {
    try {
      return await channel.invokeMethod<bool>('able') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Begins taking what the Mac plays; null where it could not be (the native half says why, in the log).
  static Future<MacShareSound?> begin() async {
    try {
      final why = await channel.invokeMethod<String>('begin');
      if (why != null) {
        debugPrint('screen sound: $why');
        return null;
      }
    } catch (e) {
      debugPrint('screen sound: not begun: $e');
      return null;
    }
    final made = _now = MacShareSound._();
    channel.setMethodCallHandler((call) async {
      final now = _now;
      final a = call.arguments is Map ? (call.arguments as Map).cast<String, Object?>() : const <String, Object?>{};
      if (now == null) return;
      switch (call.method) {
        case 'ice':
          now.onCandidate?.call('${a['id']}', {'candidate': a['candidate'], 'sdpMid': a['sdpMid'], 'sdpMLineIndex': a['sdpMLineIndex']});
        case 'link':
          now.onState?.call('${a['id']}', '${a['state']}');
      }
    });
    return made;
  }

  @override
  void Function(String id, Map<String, dynamic> candidate)? onCandidate;
  @override
  void Function(String id, String state)? onState;

  bool get _mine => identical(_now, this);

  @override
  Future<String?> offer(String id, {required List<Map<String, Object>> servers, required bool relayOnly}) async {
    if (!_mine) return null;
    try {
      return await channel.invokeMethod<String>('offer', {'id': id, 'servers': servers, 'relay': relayOnly});
    } catch (e) {
      debugPrint('screen sound: no connection to $id: $e');
      return null;
    }
  }

  @override
  Future<bool> answer(String id, String sdp) async {
    if (!_mine) return false;
    try {
      return await channel.invokeMethod<bool>('answer', {'id': id, 'sdp': sdp}) ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> candidate(String id, Map<String, dynamic> c) async {
    if (!_mine) return;
    try {
      await channel.invokeMethod<void>('ice', {'id': id, ...c});
    } catch (_) {}
  }

  @override
  Future<void> close(String id) async {
    if (!_mine) return;
    try {
      await channel.invokeMethod<void>('close', {'id': id});
    } catch (_) {}
  }

  /// Ends the tap and every connection. Another begun since is not this one's to end.
  @override
  Future<void> end() async {
    if (!_mine) return;
    _now = null;
    try {
      await channel.invokeMethod<void>('end');
    } catch (_) {}
  }
}

/// Makes a viewer's connection to [who]'s sound: as the music's ([MakeEar]), and named, so two shares are two sounds.
typedef MakeShareEar = MusicEar Function({
  required String who,
  required List<Map<String, Object>> servers,
  required bool relayOnly,
  required void Function(Map<String, dynamic>) onCandidate,
  required void Function(bool up) onState,
});

class ScreenSound extends ChangeNotifier {
  ScreenSound._();
  static final ScreenSound instance = ScreenSound._();

  @visibleForTesting
  ScreenSound.forTest({required this.source, required this.makeEar, required this.clock, this.ways = _noWays, this.store, this.maySpeak = _anyone});
  static ({List<Map<String, Object>> servers, bool relay}) _noWays() => (servers: const [], relay: false);
  static bool _anyone(String id) => true;

  /// The sound of what this device shares now; null while it shares none.
  ShareSoundSource? Function() source = _sourceHere;
  MakeShareEar makeEar = _rtcEar;
  DateTime Function() clock = DateTime.now;

  /// Where a connection looks for a way through: the call's own servers, and whether the relay is among them.
  ({List<Map<String, Object>> servers, bool relay}) Function() ways = _callWays;

  /// Whether [id]'s share is one to listen to. Everyone's, as the app has it: whether someone may share at all is
  /// held at their own device (VoiceSession.videoLocked).
  bool Function(String id) maySpeak = _anyone;

  /// Where the loudness is kept; the app's own choices where none is given.
  @visibleForTesting
  AppState? store;
  AppState? get _store => store ?? Voice.instance.app;

  static ShareSoundSource? _sourceHere() {
    final m = Voice.instance.media;
    return m is ScreenSoundMedia ? (m as ScreenSoundMedia).screenSound : null;
  }

  static MusicEar _rtcEar({
    required String who,
    required List<Map<String, Object>> servers,
    required bool relayOnly,
    required void Function(Map<String, dynamic>) onCandidate,
    required void Function(bool up) onState,
  }) =>
      RtcMusicEar(servers: servers, relayOnly: relayOnly, onCandidate: onCandidate, onState: onState, onLossless: (_, _) {}, who: 'ghost-share-$who');

  static ({List<Map<String, Object>> servers, bool relay}) _callWays() {
    final m = Voice.instance.media;
    return m == null ? (servers: RtcMedia.defaultIce, relay: false) : (servers: m.iceServers, relay: m.hasRelay);
  }

  /// How often one viewer may ask for a connection, the most viewers sent a share's sound, the most shares listened
  /// to at once, and the longest description and way to connect taken from the room.
  static const linkEvery = Duration(seconds: 2);
  static const viewersMost = 60, sharesMost = 4, sdpMost = 24000, candidateMost = 800;

  // --- the call ----------------------------------------------------------------------------------------------------------

  VoiceSession? _session;

  /// Follows the call [Voice] is in.
  void follow() => followSession(Voice.instance.session);

  void followSession(VoiceSession? s) {
    if (identical(s, _session)) return;
    final was = _session;
    was?.onShareSound = null;
    was?.removeListener(_callChanged);
    unawaited(_endSharing());
    for (final id in _ears.keys.toList()) {
      unawaited(_dropEar(id));
    }
    _session = s;
    _linkAt.clear();
    if (s != null) {
      s.onShareSound = _heard;
      s.addListener(_callChanged);
      _callChanged();
    }
    notifyListeners();
  }

  /// Anything in the call changed: who shares with sound, who is in it, this device deafened or sharing.
  void _callChanged() {
    final s = _session;
    if (s == null) return;
    // This device's own share: its sound's connections are made while it shares with sound, and ended with it.
    final mine = s.screen && s.screenSound ? source() : null;
    if (!identical(mine, _source)) {
      unawaited(_endSharing());
      if (mine != null) _begin(mine);
    }
    if (_source != null) {
      for (final id in _links.keys.toList()) {
        if (!s.members.containsKey(id)) unawaited(_dropLink(id));
      }
    }
    _tune();
  }

  /// Something said of a share's sound by [from].
  void _heard(String from, Map<String, dynamic> m) {
    final s = _session;
    if (s == null || !s.members.containsKey(from) || m['to'] != s.route.me) return;
    switch (m['k']) {
      case 'ask':
        if (_source != null) unawaited(_offerTo(from, m['n']));
      case 'ans':
        if (_source != null) unawaited(_answered(from, m));
      case 'offer':
        unawaited(_offered(from, m));
      case 'ice':
        unawaited(_heardIce(from, m));
    }
  }

  // --- the connections, the sharer's side -----------------------------------------------------------------------------

  ShareSoundSource? _source;

  /// Each viewer's connection, by its mark: what is said of another is not for it.
  final Map<String, String> _links = {};
  final Map<String, DateTime> _linkAt = {};

  /// How many viewers this device's share's sound is being sent to.
  int get sendingTo => _links.length;

  void _begin(ShareSoundSource source) {
    _source = source;
    source.onCandidate = (id, c) {
      final l = _links[id];
      if (l != null && identical(source, _source)) _session?.sayShareSound({'k': 'ice', 'to': id, 'l': l, 'c': c});
    };
    source.onState = (id, state) {
      if (identical(source, _source) && (state == 'failed' || state == 'closed')) unawaited(_dropLink(id));
    };
  }

  Future<void> _endSharing() async {
    final source = _source;
    _source = null;
    _links.clear();
    if (source == null) return;
    source.onCandidate = null;
    source.onState = null;
    await source.end().catchError((_) {});
  }

  Future<void> _offerTo(String id, Object? tries) async {
    final s = _session, source = _source;
    if (s == null || source == null) return;
    final now = clock();
    final last = _linkAt[id];
    if (last != null && now.difference(last) < linkEvery) return;
    if (!_links.containsKey(id) && _links.length >= viewersMost) return;
    _linkAt[id] = now;
    final mark = _links[id] = NetCrypto.hex(NetCrypto.randomBytes(8));
    final w = ways();
    // Through the relay alone first where there is one, as the call's own connections are; every path the next time.
    final relay = w.relay && (tries is! int || tries.isEven);
    final sdp = await source.offer(id, servers: w.servers, relayOnly: relay).catchError((_) => null);
    if (_links[id] != mark || !identical(source, _source)) return;
    if (sdp == null) {
      _links.remove(id);
      return;
    }
    s.sayShareSound({'k': 'offer', 'to': id, 'l': mark, 'sdp': sdp, if (relay) 'r': 1});
  }

  Future<void> _answered(String from, Map<String, dynamic> m) async {
    final mark = _links[from], sdp = m['sdp'];
    if (mark == null || m['l'] != mark || sdp is! String || sdp.length > sdpMost) return;
    final ok = await _source?.answer(from, sdp).catchError((_) => false) ?? false;
    if (!ok && _links[from] == mark) await _dropLink(from);
  }

  Future<void> _dropLink(String id) async {
    if (_links.remove(id) == null) return;
    await _source?.close(id).catchError((_) {});
  }

  Future<void> _heardIce(String from, Map<String, dynamic> m) async {
    final c = m['c'];
    if (c is! Map || m['l'] is! String) return;
    final line = c['candidate'], mid = c['sdpMid'], at = c['sdpMLineIndex'];
    if (line is! String || line.length > candidateMost) return;
    final way = <String, dynamic>{'candidate': line, 'sdpMid': mid is String && mid.length < 40 ? mid : '', 'sdpMLineIndex': at is int && at >= 0 && at < 8 ? at : 0};
    if (_source != null && _links[from] == m['l']) {
      await _source?.candidate(from, way).catchError((_) {});
      return;
    }
    final ear = _ears[from];
    if (ear != null && ear.mark == m['l']) {
      try {
        await ear.ear?.candidate(way);
      } catch (_) {}
    }
  }

  // --- the viewer ----------------------------------------------------------------------------------------------------------

  /// What is heard, or asked for, of each sharer's sound.
  final Map<String, _Hearing> _ears = {};

  static const volumeKey = 'share_volume';

  /// How loud a share's sound is here, 0 to 100. At 0 it is not asked for at all.
  int get volume => (int.tryParse(_store?.choice(volumeKey, '100') ?? '100') ?? 100).clamp(0, 100);

  void setVolume(int to) {
    _store?.keep(volumeKey, '${to.clamp(0, 100)}');
    _tune();
    notifyListeners();
  }

  /// Whether [id] shares their screen with its sound, as they say.
  bool sounds(String id) {
    final s = _session;
    return s != null && (s.members[id]?.screen ?? false) && s.sharingSound.contains(id) && maySpeak(id);
  }

  /// Whether [id]'s share's sound is coming to this device now.
  bool hearing(String id) => _ears[id]?.through ?? false;

  /// Whose sound this device wants now: everyone who shares with sound, while it is not turned all the way down.
  Set<String> _wanted() {
    final s = _session;
    if (s == null || volume == 0) return const {};
    return {
      for (final id in s.members.keys)
        if (sounds(id)) id,
    }.take(sharesMost).toSet();
  }

  /// The connections as they should be: asked for, let go of, and as loud as they are to be.
  void _tune() {
    final want = _wanted();
    for (final id in _ears.keys.toList()) {
      if (!want.contains(id)) unawaited(_dropEar(id));
    }
    for (final id in want) {
      final h = _ears.putIfAbsent(id, _Hearing.new);
      if (h.ear == null && h.askTimer == null) _askNow(id);
    }
    _loud();
  }

  void _loud() {
    final s = _session;
    final out = Voice.instance.media?.settings.outputVolume ?? 100;
    for (final h in _ears.values) {
      h.ear?.set(volume: volume / 100 * out / 100, silent: s == null || s.deafened);
    }
  }

  /// Asks [id] for a connection, and again, further apart each time, until it is through.
  void _askNow(String id) {
    final s = _session, h = _ears[id];
    if (s == null || h == null || !_wanted().contains(id)) return;
    s.sayShareSound({'k': 'ask', 'to': id, 'n': h.tries});
    final wait = Duration(seconds: [4, 8, 16, 30][h.tries.clamp(0, 3)]);
    h.tries++;
    h.askTimer = Timer(wait, () {
      h.askTimer = null;
      if (identical(_ears[id], h) && h.ear == null) _askNow(id);
    });
  }

  /// [from]'s offer, for a connection this device asked for.
  Future<void> _offered(String from, Map<String, dynamic> m) async {
    final s = _session, mark = m['l'], sdp = m['sdp'];
    final h = _ears[from];
    if (s == null || h == null || !_wanted().contains(from) || mark is! String || mark.length > 40 || sdp is! String || sdp.length > sdpMost) return;
    await _closeEar(h);
    if (!identical(s, _session) || !identical(_ears[from], h)) return;
    h.mark = mark;
    late final MusicEar ear;
    ear = h.ear = makeEar(
      who: from,
      servers: ways().servers,
      relayOnly: m['r'] == 1,
      onCandidate: (c) {
        if (identical(h.ear, ear)) _session?.sayShareSound({'k': 'ice', 'to': from, 'l': mark, 'c': c});
      },
      onState: (up) {
        if (!identical(h.ear, ear)) return;
        h.through = up;
        if (up) {
          h.tries = 0;
          h.askTimer?.cancel();
          h.askTimer = null;
        } else {
          // Lost, or never through: let go of, and asked for again.
          unawaited(_closeEar(h).then((_) {
            if (identical(_ears[from], h) && h.ear == null && h.askTimer == null) _askNow(from);
          }));
        }
        notifyListeners();
      },
    );
    _loud();
    unawaited(ear.output(Voice.instance.media?.speaker.value ?? '').catchError((_) {}));
    try {
      final answer = await ear.takeOffer(sdp);
      if (identical(h.ear, ear)) _session?.sayShareSound({'k': 'ans', 'to': from, 'l': mark, 'sdp': answer});
    } catch (e) {
      debugPrint('screen sound: $from\'s offer not taken: $e');
      if (identical(h.ear, ear)) await _closeEar(h);
    }
  }

  /// Lets go of the connection [h] has, keeping its place: it may be asked for again.
  Future<void> _closeEar(_Hearing h) async {
    final ear = h.ear;
    h.ear = null;
    h.mark = null;
    final was = h.through;
    h.through = false;
    await ear?.close();
    if (was) notifyListeners();
  }

  Future<void> _dropEar(String id) async {
    final h = _ears.remove(id);
    if (h == null) return;
    h.askTimer?.cancel();
    h.askTimer = null;
    await _closeEar(h);
  }
}

/// One sharer's sound on this device: the connection it comes by, once offered, and the asking for it.
class _Hearing {
  MusicEar? ear;
  String? mark;
  bool through = false;
  int tries = 0;
  Timer? askTimer;
}
