/// A listener's connection to the music (lib/voice/spotify.dart): an ordinary one that only receives, to the DJ's
/// device, with a loudness of its own on this one, and the music without loss beside the Opus on it where the DJ sends that
/// and this device has a player for it (spotify_lossless.dart). Beside the call's own connections and never among them: a recording,
/// captions and Scribe take the people's sounds (RtcMedia.sounds), and this is in none of them.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'call_sound.dart';
import 'music_sink.dart';
import 'rtc.dart';
import 'spotify_app.dart' show musicOpus;
import 'spotify_lossless.dart';

/// What the session asks of a listener's connection: WebRTC's ([RtcMusicEar]), or a test's.
abstract class MusicEar {
  /// Takes the DJ's offer; this side's answer.
  Future<String> takeOffer(String sdp);
  Future<void> candidate(Map<String, dynamic> c);

  /// How loud, 0 to 1, and whether it is heard at all (deafened, it is not).
  void set({required double volume, required bool silent});

  /// How loud the music is now, 0 to 1, as it comes in (before the loudness of this device).
  Future<double> level();

  /// The speaker chosen, for what WebRTC doesn't play itself (a browser; the music without loss).
  Future<void> output(String deviceId);

  /// Whether the music is to be taken without loss too, where the DJ sends it.
  void lossless(bool take);

  /// Whether the DJ plays now.
  void playing(bool on);
  Future<void> close();
}

/// Makes an ear: [servers] as the call has them, [relayOnly] as the DJ made their side, [onCandidate] told each way to
/// connect found here, [onState] whether it is through (true), or lost for good (false), and [onLossless] whether the music
/// is heard without loss, and why it won't be where that is so.
typedef MakeEar = MusicEar Function({
  required List<Map<String, Object>> servers,
  required bool relayOnly,
  required void Function(Map<String, dynamic>) onCandidate,
  required void Function(bool up) onState,
  required void Function(bool heard, LosslessWhy? why) onLossless,
});

class RtcMusicEar implements MusicEar {
  RtcMusicEar({required this.servers, required this.relayOnly, required this.onCandidate, required this.onState, required this.onLossless, this.who = 'ghost-music'});

  /// What its sound is played as, where the page plays it (a browser): the music's, or one sharer's screen's
  /// (lib/voice/screen_sound.dart), so two of them are two sounds.
  final String who;
  final List<Map<String, Object>> servers;
  final bool relayOnly;
  final void Function(Map<String, dynamic>) onCandidate;
  final void Function(bool up) onState;
  final void Function(bool heard, LosslessWhy? why) onLossless;

  static MusicEar make({
    required List<Map<String, Object>> servers,
    required bool relayOnly,
    required void Function(Map<String, dynamic>) onCandidate,
    required void Function(bool up) onState,
    required void Function(bool heard, LosslessWhy? why) onLossless,
  }) =>
      RtcMusicEar(servers: servers, relayOnly: relayOnly, onCandidate: onCandidate, onState: onState, onLossless: onLossless);

  /// The player the music without loss goes to; a test's own.
  @visibleForTesting
  static MusicSink? Function() makeSink = MusicSink.here;

  /// Not through this long after it began, or lost for this long: given up on, and asked for again.
  static const connectWithin = Duration(seconds: 15), lostFor = Duration(seconds: 6);

  Future<RTCPeerConnection>? _pc;
  final List<RTCIceCandidate> _early = [];
  final List<MediaStreamTrack> _tracks = [];
  bool _described = false, _closed = false;
  Timer? _patience;
  double _volume = 1;
  bool _silent = false;
  final CallSound _out = CallSound();

  Future<RTCPeerConnection> get _made => _pc ??= _make();

  Future<RTCPeerConnection> _make() async {
    final pc = await RtcMedia.make({'iceServers': servers, 'sdpSemantics': 'unified-plan', if (relayOnly) 'iceTransportPolicy': 'relay'});
    pc.onIceCandidate = (c) {
      if (c.candidate != null && !_closed) onCandidate({'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex});
    };
    pc.onTrack = (e) {
      RtcMedia.note(pc, e.track);
      if (_closed || e.track.kind != 'audio') return;
      if (!_tracks.any((t) => t.id == e.track.id)) _tracks.add(e.track);
      _out.play(who, e.track);
      _apply();
    };
    pc.onDataChannel = _opened;
    pc.onConnectionState = (s) {
      if (_closed) return;
      switch (s) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _patience?.cancel();
          onState(true);
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          _wait(lostFor);
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed || RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          _lost();
        default:
      }
    };
    return pc;
  }

  void _wait(Duration most) {
    _patience?.cancel();
    _patience = Timer(most, _lost);
  }

  void _lost() {
    _patience?.cancel();
    if (!_closed) onState(false);
  }

  @override
  Future<String> takeOffer(String sdp) async {
    _wait(connectWithin);
    final pc = await _made;
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    _described = true;
    for (final c in _early) {
      try {
        await pc.addCandidate(c);
      } catch (_) {}
    }
    _early.clear();
    // Only ever listening: nothing of this device's is put in it.
    final answer = await pc.createAnswer();
    final mine = musicOpus(answer.sdp ?? '');
    await pc.setLocalDescription(RTCSessionDescription(mine, 'answer'));
    return mine;
  }

  @override
  Future<void> candidate(Map<String, dynamic> m) async {
    final c = RTCIceCandidate(m['candidate'] as String?, m['sdpMid'] as String?, (m['sdpMLineIndex'] as num?)?.toInt());
    if (!_described) {
      if (_early.length < 64) _early.add(c);
      return;
    }
    await (await _made).addCandidate(c);
  }

  @override
  void set({required double volume, required bool silent}) {
    _volume = volume;
    _silent = silent;
    _apply();
  }

  void _apply() {
    if (CallSound.playsItself) {
      _out.set(who, volume: _volume, silent: _silent);
      return;
    }
    final ear = _lossless;
    ear?.set(volume: _volume, silent: _silent);
    for (final t in _tracks) {
      // The one that is heard is the one without loss, while it is: never both.
      t.enabled = !_silent && !(ear?.heard ?? false);
      unawaited(Helper.setVolume(_volume, t).catchError((_) {}));
    }
  }

  // --- without loss ----------------------------------------------------------------------------------------------------

  LosslessEar? _lossless;
  RTCDataChannel? _channel;
  bool _take = false, _playing = true;
  String _speaker = '';

  /// The DJ opened a channel on the connection: the music without loss, where it is to be taken. The newest is the one.
  void _opened(RTCDataChannel channel) {
    if (_closed || channel.label != losslessLabel || !_take) {
      unawaited(channel.close().catchError((_) {}));
      return;
    }
    final sink = makeSink();
    if (sink == null) return;
    _endLossless();
    _channel = channel;
    late final LosslessEar ear;
    ear = _lossless = LosslessEar(
      sink: sink,
      onHeard: (on) {
        if (!identical(_lossless, ear)) return;
        _apply();
        onLossless(on, null);
      },
      onGiveUp: (why) {
        if (!identical(_lossless, ear)) return;
        _endLossless();
        onLossless(false, why);
      },
    )
      ..device = _speaker
      ..playing = _playing
      ..set(volume: _volume, silent: _silent);
    channel.onMessage = (m) {
      if (identical(_channel, channel) && m.isBinary) ear.take(m.binary);
    };
    channel.onDataChannelState = (s) {
      if (s == RTCDataChannelState.RTCDataChannelClosed && identical(_channel, channel)) _endLossless();
    };
  }

  /// No more of it: the Opus is heard.
  void _endLossless() {
    final ear = _lossless, channel = _channel;
    _lossless = null;
    _channel = null;
    final heard = ear?.heard ?? false;
    ear?.close();
    if (channel != null) unawaited(channel.close().catchError((_) {}));
    if (heard && !_closed) {
      _apply();
      onLossless(false, null);
    }
  }

  @override
  void lossless(bool take) {
    _take = take;
    if (!take) _endLossless();
  }

  @override
  void playing(bool on) {
    _playing = on;
    _lossless?.playing = on;
  }

  @override
  Future<double> level() async {
    final ear = _lossless;
    if (ear != null && ear.heard) return ear.level();
    final made = _pc;
    if (made == null || _closed || _tracks.isEmpty) return 0;
    try {
      for (final r in await (await made).getStats()) {
        if ((r.type == 'inbound-rtp' || r.type == 'track') && r.values['audioLevel'] is num) return (r.values['audioLevel'] as num).toDouble().clamp(0.0, 1.0);
      }
    } catch (_) {}
    return 0;
  }

  @override
  Future<void> output(String deviceId) async {
    _speaker = deviceId;
    _lossless?.output(deviceId);
    if (CallSound.playsItself) await _out.output(deviceId);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _patience?.cancel();
    _endLossless();
    _out.stopAll();
    final made = _pc;
    if (made == null) return;
    try {
      final pc = await made;
      await RtcMedia.closeConnection(pc);
      await pc.dispose();
    } catch (e) {
      debugPrint('spotify: music connection not closed: $e');
    }
  }
}
