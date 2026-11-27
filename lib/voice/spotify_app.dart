/// The Spotify app on this computer and its sound, as the DJ's device reaches them (lib/voice/spotify.dart): what
/// presses Spotify's own buttons ([SpotifyApp]) and what sends its sound to each listener ([MusicSource]), for a Mac and
/// for a PC. Nothing signs in to Spotify, decodes it or needs a key of its API; a browser, a phone and Linux have
/// neither, and can only listen and choose songs.
///
/// - **A Mac** (macos/Runner/Spotify.swift): AppleScript, a Core Audio tap on Spotify's processes, and connections of a
///   WebRTC of its own whose sound device is that sound.
/// - **A PC** (windows/runner/spotify.cpp): a song is opened as a link, everything else is Windows' own media controls,
///   and the sound is WASAPI's loopback of Spotify's process tree as a track of flutter_webrtc's own, sent on ordinary
///   connections made here.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../platform_info.dart';
import 'rtc.dart';
import 'spotify_deck.dart';
import 'spotify_lossless.dart';
import 'spotify_queue.dart';
import 'voice.dart' show highestOpus;
import 'voice_fx.dart';
import 'voice_settings.dart';

/// How the music is sent: Opus in stereo at the most it has, with no silence left out and none of its bits spent on
/// saying things twice in case they are lost, which takes them from the music (Matt, 2026-11-25: "the audio doesn't sound
/// high quality for the other user they said it sounds compressed").
const musicKbps = 510;
String musicOpus(String sdp) => highestOpus(sdp, kbps: musicKbps, fec: false);

/// Why Spotify did not do as it was asked: one of [MusicTrouble]'s words.
class SpotifyRefused implements Exception {
  const SpotifyRefused(this.word);
  final String word;
  @override
  String toString() => 'Spotify: $word';
}

/// What can be told of Spotify on this computer without touching it.
typedef SpotifyAble = ({bool system, bool installed, bool running});

/// Spotify's own buttons. Each throws [SpotifyRefused] where it can't be pressed.
abstract class SpotifyApp {
  bool get mac;

  /// Asking for a song may only show it ([SpotifyDeck.opens]).
  bool get opens;

  Future<SpotifyAble> able();

  /// What Spotify is doing.
  Future<SpotifyNow> now();

  /// Plays the track [id]: only ever one [isTrackId] takes.
  Future<void> play(String id);
  Future<void> pause();
  Future<void> resume();
  Future<void> seek(Duration to);

  /// Told when Spotify is closed, or crashes.
  void Function()? onQuit;

  /// This computer's; null where there is none to press.
  static SpotifyApp? here() => kIsWeb ? null : (PlatformInfo.isMacOS ? MacSpotify.instance : (PlatformInfo.isWindows ? WindowsSpotify.instance : null));
}

/// Spotify's sound, and the connections that send it: one to each listener, each sending and never receiving.
abstract class MusicSource {
  /// Begins taking the sound. Throws [SpotifyRefused] where it can't be.
  Future<void> begin();

  /// Ends all of it: no sound taken, no connection left.
  Future<void> end();

  /// How loud it has been since last asked, 0 to 1: nothing at all for long is a refusal, or the wrong device.
  Future<double> level();

  /// A connection to [id], made anew, and its offer; null where it could not be made. [lossless]: with a channel for the
  /// music without loss, which is sent on it once the connection is known to go through no relay ([losslessState]).
  Future<String?> offer(String id, {required List<Map<String, Object>> servers, required bool relayOnly, required bool lossless});
  Future<bool> answer(String id, String sdp);
  Future<void> candidate(String id, Map<String, dynamic> c);
  Future<void> close(String id);

  /// Begins to send [id] the music without loss again on the connection there is, or ends it; the Opus goes on.
  Future<void> lossless(String id, {required bool on});

  /// How that goes for each who has it. Asking is also what lets it be sent, or stops it: only where the connection goes
  /// through no relay.
  Future<Map<String, LosslessState>> losslessState();

  /// The rate the sound is taken at, 0 where it isn't known. Below 44,100 it is not the music whole, however it is sent.
  Future<double> rate();

  void Function(String id, Map<String, dynamic> candidate)? onCandidate;

  /// How a connection stands: `connected`, `failed`, `closed`, or anything between.
  void Function(String id, String state)? onState;

  static MusicSource? here(VoiceSettings settings) => kIsWeb ? null : (PlatformInfo.isMacOS ? MacSpotify.instance : (PlatformInfo.isWindows ? WindowsMusic(settings) : null));
}

/// The `ghost/spotify` channel: one handler for what comes from the native half.
abstract final class SpotifyChannel {
  static const channel = MethodChannel('ghost/spotify');

  static Future<T?> ask<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw SpotifyRefused(MusicTrouble.words.containsKey(e.code) ? e.code : MusicTrouble.failed);
    } on MissingPluginException {
      throw const SpotifyRefused(MusicTrouble.failed);
    }
  }

  static Future<SpotifyAble> able() async {
    try {
      final m = await channel.invokeMapMethod<String, Object?>('able') ?? const {};
      return (system: m['system'] == true, installed: m['installed'] == true, running: m['running'] == true);
    } catch (_) {
      return (system: false, installed: false, running: false);
    }
  }
}

/// The Mac's half: both at once, as they share the one channel.
class MacSpotify implements SpotifyApp, MusicSource {
  MacSpotify._();
  static final MacSpotify instance = MacSpotify._();

  @override
  void Function()? onQuit;
  @override
  void Function(String id, Map<String, dynamic> candidate)? onCandidate;
  @override
  void Function(String id, String state)? onState;

  @override
  bool get mac => true;
  @override
  bool get opens => false;

  @override
  Future<SpotifyAble> able() => SpotifyChannel.able();

  @override
  Future<SpotifyNow> now() async => SpotifyNow.from(await SpotifyChannel.ask<Map<Object?, Object?>>('now') ?? const {});

  @override
  Future<void> play(String id) async {
    if (!isTrackId(id)) throw const SpotifyRefused(MusicTrouble.song);
    await SpotifyChannel.ask<void>('play', {'id': id});
  }

  @override
  Future<void> pause() => SpotifyChannel.ask<void>('pause');
  @override
  Future<void> resume() => SpotifyChannel.ask<void>('resume');
  @override
  Future<void> seek(Duration to) => SpotifyChannel.ask<void>('seek', {'ms': to.inMilliseconds});

  @override
  Future<void> begin() async {
    SpotifyChannel.channel.setMethodCallHandler((call) async {
      final a = call.arguments is Map ? (call.arguments as Map).cast<String, Object?>() : const <String, Object?>{};
      switch (call.method) {
        case 'ice':
          onCandidate?.call('${a['id']}', {'candidate': a['candidate'], 'sdpMid': a['sdpMid'], 'sdpMLineIndex': a['sdpMLineIndex']});
        case 'link':
          onState?.call('${a['id']}', '${a['state']}');
        case 'quit':
          onQuit?.call();
      }
    });
    final why = await SpotifyChannel.ask<String>('begin');
    if (why != null) throw const SpotifyRefused(MusicTrouble.sound);
  }

  @override
  Future<void> end() async {
    try {
      await SpotifyChannel.ask<void>('end');
    } catch (_) {}
  }

  @override
  Future<double> level() async => await SpotifyChannel.ask<double>('level') ?? 0;

  @override
  Future<String?> offer(String id, {required List<Map<String, Object>> servers, required bool relayOnly, required bool lossless}) =>
      SpotifyChannel.ask<String>('offer', {'id': id, 'servers': servers, 'relay': relayOnly, 'lossless': lossless});

  @override
  Future<void> lossless(String id, {required bool on}) => SpotifyChannel.ask<void>('lossless', {'id': id, 'on': on});

  @override
  Future<Map<String, LosslessState>> losslessState() async {
    final all = await SpotifyChannel.ask<Map<Object?, Object?>>('losslessState') ?? const {};
    return {
      for (final MapEntry(:key, :value) in all.entries)
        if (key is String && value is Map) key: (open: value['open'] == true, bytes: (value['bytes'] as num?)?.toInt() ?? 0, dropped: (value['dropped'] as num?)?.toInt() ?? 0, relay: value['relay'] as bool?),
    };
  }

  @override
  Future<double> rate() async => await SpotifyChannel.ask<double>('rate') ?? 0;

  @override
  Future<bool> answer(String id, String sdp) async => await SpotifyChannel.ask<bool>('answer', {'id': id, 'sdp': sdp}) ?? false;

  @override
  Future<void> candidate(String id, Map<String, dynamic> c) => SpotifyChannel.ask<void>('ice', {'id': id, ...c});

  @override
  Future<void> close(String id) => SpotifyChannel.ask<void>('close', {'id': id});
}

/// Whether Windows' name for an app is Spotify's: the desktop app's, or the Microsoft Store's. Nothing is read from, or
/// pressed in, any other player.
bool isSpotifyAppId(Object? id) {
  if (id is! String || id.length > 200) return false;
  final s = id.toLowerCase();
  return s == 'spotify.exe' || RegExp(r'^spotifyab\.spotifymusic_[a-z0-9]+!spotify$').hasMatch(s);
}

/// The PC's buttons: a song is opened by its own address, and the rest is Windows' media controls for Spotify alone.
class WindowsSpotify implements SpotifyApp {
  WindowsSpotify._();
  static final WindowsSpotify instance = WindowsSpotify._();

  @override
  void Function()? onQuit;

  @override
  bool get mac => false;
  @override
  bool get opens => true;

  @override
  Future<SpotifyAble> able() => SpotifyChannel.able();

  /// The media session that is Spotify's, of those the native half found; null where there is none yet (Spotify has one
  /// only once it has played something).
  @visibleForTesting
  static Map<Object?, Object?>? ours(List<Object?> sessions) {
    for (final s in sessions) {
      if (s is Map && isSpotifyAppId(s['app'])) return s;
    }
    return null;
  }

  @override
  Future<SpotifyNow> now() async {
    final sessions = await SpotifyChannel.ask<List<Object?>>('now') ?? const [];
    final s = ours(sessions);
    // No track's id is said on a PC: nothing that came is taken for one.
    return s == null ? const SpotifyNow() : SpotifyNow.from({...s, 'id': null, 'art': null});
  }

  @override
  Future<void> play(String id) async {
    if (!isTrackId(id)) throw const SpotifyRefused(MusicTrouble.song);
    // Never opened where it is closed: opening its address would.
    if (!(await able()).running) throw const SpotifyRefused(MusicTrouble.closed);
    await SpotifyChannel.ask<void>('play', {'id': id});
  }

  @override
  Future<void> pause() => SpotifyChannel.ask<void>('pause');
  @override
  Future<void> resume() => SpotifyChannel.ask<void>('resume');
  @override
  Future<void> seek(Duration to) => SpotifyChannel.ask<void>('seek', {'ms': to.inMilliseconds});
}

/// The PC's sound, sent on connections of flutter_webrtc's own: the native half makes one track of what Spotify plays
/// (WASAPI's loopback of Spotify's process tree and nothing else), and each listener gets a connection that only sends
/// it. The track is one the microphone never reaches: WebRTC hands a track of its own making (a custom source) what is
/// given to it and nothing of the sound device (libwebrtc m150, LocalAudioSource).
class WindowsMusic implements MusicSource {
  WindowsMusic(this.settings);

  /// The call's own: WebRTC keeps one set of sound processing for every track a device sends, and the last track
  /// added sets it. So the music's track asks for just what the microphone's does (lib/voice/rtc.dart, _audioAsked),
  /// and the microphone's echo cancelling is never switched off by it. A custom track's sound goes through none of it.
  final VoiceSettings settings;

  @override
  void Function(String id, Map<String, dynamic> candidate)? onCandidate;
  @override
  void Function(String id, String state)? onState;

  String? _track;
  final Map<String, RTCPeerConnection> _links = {};

  /// Those sent it without loss, with the channel each is sent on; whether the native half makes chunks for them.
  final Map<String, ({RTCDataChannel channel, LosslessWay way})> _ways = {};
  bool _packing = false;

  @override
  Future<void> begin() async {
    SpotifyChannel.channel.setMethodCallHandler((call) async {
      if (call.method == 'quit') WindowsSpotify.instance.onQuit?.call();
      if (call.method == 'chunk' && call.arguments is Uint8List) {
        for (final w in _ways.values) {
          w.way.push(call.arguments as Uint8List);
        }
      }
    });
    final id = await SpotifyChannel.ask<String>('begin', {'echo': settings.useEcho, 'noise': settings.noiseOn(VoiceFx.available) == NoiseMode.webrtc, 'gain': settings.useGain});
    if (id == null || id.isEmpty) throw const SpotifyRefused(MusicTrouble.sound);
    _track = id;
  }

  @override
  Future<void> end() async {
    for (final id in _links.keys.toList()) {
      await close(id);
    }
    _track = null;
    try {
      await SpotifyChannel.ask<void>('end');
    } catch (_) {}
  }

  @override
  Future<double> level() async => await SpotifyChannel.ask<double>('level') ?? 0;

  @override
  Future<String?> offer(String id, {required List<Map<String, Object>> servers, required bool relayOnly, required bool lossless}) async {
    final track = _track;
    if (track == null) return null;
    await close(id);
    final pc = await RtcMedia.make({'iceServers': servers, 'sdpSemantics': 'unified-plan', if (relayOnly) 'iceTransportPolicy': 'relay'});
    // Ended while it was being made.
    if (_track != track) {
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
        track: _MadeTrack(track),
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendOnly, streams: const [], sendEncodings: [RTCRtpEncoding(maxBitrate: musicKbps * 1000)]),
      );
      RtcMedia.note(pc, way.sender);
      if (lossless) await _openWay(id, pc);
      final made = await pc.createOffer();
      final sdp = musicOpus(made.sdp ?? '');
      await pc.setLocalDescription(RTCSessionDescription(sdp, 'offer'));
      return sdp;
    } catch (e) {
      debugPrint('spotify: no connection to $id: $e');
      await close(id);
      return null;
    }
  }

  @override
  Future<bool> answer(String id, String sdp) async {
    final pc = _links[id];
    if (pc == null) return false;
    try {
      await pc.setRemoteDescription(RTCSessionDescription(musicOpus(sdp), 'answer'));
      return true;
    } catch (e) {
      debugPrint('spotify: $id\'s answer not taken: $e');
      return false;
    }
  }

  @override
  Future<void> candidate(String id, Map<String, dynamic> c) async {
    try {
      await _links[id]?.addCandidate(RTCIceCandidate(c['candidate'] as String?, c['sdpMid'] as String?, (c['sdpMLineIndex'] as num?)?.toInt()));
    } catch (_) {}
  }

  Future<void> _openWay(String id, RTCPeerConnection pc) async {
    // No number of its own choosing (-1): WebRTC gives the next one free, as the one before may still be closing.
    final channel = await pc.createDataChannel(losslessLabel, RTCDataChannelInit()
      ..ordered = true
      ..id = -1);
    if (!identical(_links[id], pc)) return;
    final way = LosslessWay(send: (c) => channel.send(RTCDataChannelMessage.fromBinary(c)), buffered: channel.getBufferedAmount);
    _ways[id] = (channel: channel, way: way);
    channel.onDataChannelState = (s) => way.isOpen = s == RTCDataChannelState.RTCDataChannelOpen;
    await _pack();
  }

  Future<void> _closeWay(String id) async {
    final w = _ways.remove(id);
    if (w == null) return;
    w.way.isOpen = false;
    await w.channel.close().catchError((_) {});
    await _pack();
  }

  /// The native half makes chunks only while someone is to have them.
  Future<void> _pack() async {
    final on = _ways.isNotEmpty;
    if (on == _packing) return;
    _packing = on;
    try {
      await SpotifyChannel.ask<void>('pack', {'on': on});
    } catch (_) {}
  }

  @override
  Future<void> lossless(String id, {required bool on}) async {
    await _closeWay(id);
    final pc = _links[id];
    if (on && pc != null) await _openWay(id, pc);
  }

  @override
  Future<Map<String, LosslessState>> losslessState() async {
    final out = <String, LosslessState>{};
    for (final MapEntry(key: id, value: w) in _ways.entries.toList()) {
      final pc = _links[id];
      if (pc == null) continue;
      bool? relay;
      try {
        relay = relayed(await pc.getStats());
      } catch (_) {}
      if (relay != null) w.way.allowed = !relay;
      out[id] = (open: w.way.isOpen, bytes: w.way.bytes, dropped: w.way.dropped, relay: relay);
    }
    return out;
  }

  /// Whether either end of the way a connection goes now is a relay's; null where that can't be told.
  @visibleForTesting
  static bool? relayed(List<StatsReport> all) {
    final by = {for (final r in all) r.id: r};
    final way = [for (final r in all) if (r.type == 'transport') r.values['selectedCandidatePairId']].whereType<String>().firstOrNull;
    final pair = by[way]?.values;
    if (pair == null) return null;
    final ends = [for (final end in const ['localCandidateId', 'remoteCandidateId']) by[pair[end]]?.values['candidateType']];
    if (ends.contains('relay')) return true;
    return ends.every((e) => e is String) ? false : null;
  }

  @override
  Future<double> rate() async => await SpotifyChannel.ask<double>('rate') ?? 0;

  @override
  Future<void> close(String id) async {
    await _closeWay(id);
    final pc = _links.remove(id);
    if (pc == null) return;
    await RtcMedia.closeConnection(pc).catchError((_) {});
    await pc.dispose().catchError((_) {});
  }
}

/// A track the native half made, by its name: all a connection asks of it.
class _MadeTrack implements MediaStreamTrack {
  _MadeTrack(this.id);
  @override
  final String id;
  @override
  String get kind => 'audio';
  @override
  bool enabled = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
