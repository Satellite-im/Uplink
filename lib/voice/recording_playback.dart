/// A recording kept on this device opened again in the timeline and the mixer (Matt, 2026-11-21: "I'd like to be able
/// to open recordings saved from calls in the multi track view with the mixer").
///
/// The MP4 has everyone mixed as its first track and each person as a track of their own (lib/voice/recorder.dart).
/// Opening it decodes each person's track to 48 kHz mono samples on the device (ghost/scribe 'decode': android
/// Scribe.kt, macos/ios Scribe.swift, windows/runner/speech.cpp, the decoders Scribe already reads tracks with), kept
/// in a folder beside the recordings so it opens at once the next time. From those: each track's waveform, its meter
/// at the playhead, and a player for each voice, all started, stopped and moved together, so what is heard is the
/// voices as the faders, mutes and solos have them now. Saving makes a new recording beside the first: everyone mixed
/// as the mixer stands, and each person's track as it was (CallRecorder.makeMp4); the first is never changed.
library;

import 'dart:async';
import 'dart:io';
import '../platform_info.dart';
import '../aside.dart';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:video_player/video_player.dart';

import 'mp4_names.dart';
import 'mpv_property.dart';
import 'recorder.dart';

/// Whether [name] is what a call's recording is named when it leaves the device: `rec` and its number, as the file is
/// named where it is made (CallRecorder), which is the name it goes up under into a circle's Files space or a space's
/// chat. A file named so is worth bringing down whole to look inside ([recordingIn]); any other is only looked into
/// where it is on this device already.
bool namedAsRecording(String name) => RegExp(r'^rec[0-9a-f]+\.mp4$', caseSensitive: false).hasMatch(name);

/// The call's recording in the file at [path], to open in the mixer, or null where it is not one (Matt, 2026-11-23:
/// "i want to see the mixer when viewing sounds recordings but it just loads the media player view": a recording
/// opened from a Files space or a chat went to the video player, as any MP4 does).
///
/// A recording is known by what the recorder wrote in it (lib/voice/mp4_names.dart): sound in every track, the first
/// named Everyone, then a track for each voice. One with a picture in it is left to the player, which shows it: a
/// recording made with video (GMFB-42) opened from a Files space or a chat plays there with its picture. From the list
/// of recordings it still opens in the mixer, which reads the voices and never the video (it is the last track).
/// Where the file is one this device made and still keeps, that one is given, with its marks and its space. Else one
/// is made up for it under [id], with [space] as the word for where it is from; it is in no list, and the voices
/// decoded for it are deleted when it is closed ([RecordingPlayback.passing]).
///
/// Null too where this device can't open one: a browser and Linux have no decoder for the tracks (ghost/scribe).
Future<Recording?> recordingIn(String path, {required String id, String space = ''}) async {
  if (!RecordingPlayback.opensHere) return null;
  try {
    final file = File(path);
    final tracks = await Mp4Names.tracks(path);
    if (tracks.length < 2 || tracks.first.name != 'Everyone' || tracks.any((t) => t.kind != 'soun')) return null;
    final people = [for (final t in tracks.skip(1)) t.name];
    // This device's own, by its name and its size: opened as it is from the list of recordings.
    final name = path.split(RegExp(r'[/\\]')).last;
    final own = name.toLowerCase().endsWith('.mp4') ? name.substring(0, name.length - 4) : name;
    for (final k in CallRecorder.instance.kept) {
      final mine = File(k.path);
      if (k.id == own && k.people.length == people.length && mine.existsSync() && mine.lengthSync() == file.lengthSync()) return k;
    }
    return Recording(id: id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_'), path: path, space: space, at: file.lastModifiedSync(), seconds: 0, people: people);
  } catch (e) {
    debugPrint('recording in a file: $e');
    return null;
  }
}

/// One kept recording open in the timeline and the mixer: its voices decoded, played together and metered, with the
/// faders, mutes and solos a live recording has ([RecordingDesk]); [save] makes the remix.
class RecordingPlayback extends ChangeNotifier implements RecordingDesk {
  RecordingPlayback(this.recording);

  /// Open already with [levels] as each voice's waveform (by key, `v1`…) and the playhead at [atSecond], for a picture
  /// or a test: nothing is decoded and nothing plays.
  @visibleForTesting
  RecordingPlayback.standing(this.recording, {required Map<String, List<double>> levels, double atSecond = 0, Map<String, ({double peak, double rms})> now = const {}}) {
    opening = null;
    meter.load(levels);
    meter.at(now);
    length = levels.values.fold<int>(0, (n, l) => math.max(n, l.length)) * RecordingMeter.step;
    position = (atSecond * rate).round();
  }

  final Recording recording;

  /// Whether this device opens a recording in the mixer: where the platform decodes a track (android Scribe.kt,
  /// macos/ios Scribe.swift, windows/runner/speech.cpp). Not a browser, and not Linux.
  static bool get opensHere => opensHereForTest ?? (!kIsWeb && (PlatformInfo.isAndroid || PlatformInfo.isIOS || PlatformInfo.isMacOS || PlatformInfo.isWindows));

  /// For a test: [opensHere]'s answer, whatever it runs on.
  @visibleForTesting
  static bool? opensHereForTest;

  /// A recording opened from a file that is in no list here (a Files space's, a chat's: [recordingIn]): the voices
  /// decoded for it are deleted when it is closed. They are as big as the sound itself, about 11 MB a minute a voice,
  /// and nothing else would ever delete them (a kept recording's go when it is deleted).
  bool passing = false;

  static const _channel = MethodChannel('ghost/scribe');

  /// Samples a second in every decoded track: positions and lengths here are counted in them.
  static const rate = 48000;

  @override
  final RecordingMeter meter = RecordingMeter();

  @override
  final RecordingMix mix = RecordingMix();

  /// Each voice's key: `v1`, `v2`… in the file's order after the mix.
  late final List<String> keys = [for (var i = 1; i <= recording.people.length; i++) 'v$i'];

  @override
  List<({String key, String name, bool live})> get tracks => [for (var i = 0; i < keys.length; i++) (key: keys[i], name: recording.people[i], live: true)];

  @override
  List<double> get markers => recording.markers;

  /// Opening: how far, 0 to 1; null once open or failed.
  double? opening = 0;

  /// Why it couldn't be opened, in words; null while it can.
  String? error;

  bool get ready => opening == null && error == null;

  /// How long it is, in samples.
  int length = 0;

  /// Where the playhead is, in samples.
  int position = 0;
  bool playing = false;
  bool _disposed = false;

  double get seconds => length / rate;
  double get at => position / rate;

  // By voice, in [keys]' order: its decoded samples' file, a reader of that file for the meters, and its player.
  // [_clock] follows the players while they play.
  final List<String> _pcm = [];
  final List<RandomAccessFile> _readers = [];
  final List<_VoicePlayer> _players = [];
  Timer? _clock;
  int _tick = 0;

  /// Where a recording's tracks are kept once decoded, to open at once the next time.
  static Directory folderFor(Recording r) => Directory('${CallRecorder.folder().path}/opened/${r.id}');

  /// Decodes the voices, works out their waveforms and readies a player for each.
  Future<void> open() async {
    try {
      if (keys.isEmpty) throw StateError('This recording has no voices of its own to mix.');
      final dir = folderFor(recording)..createSync(recursive: true);
      final made = File(recording.path).lastModifiedSync();
      for (var i = 0; i < keys.length; i++) {
        final pcm = '${dir.path}/${keys[i]}.pcm';
        final f = File(pcm);
        // Decoded before, from this same file: used as it is.
        if (!f.existsSync() || f.lastModifiedSync().isBefore(made) || f.lengthSync() == 0) {
          final raw = '${dir.path}/${keys[i]}.raw';
          final got = await _channel.invokeMethod<Map>('decode', {'path': recording.path, 'track': i + 1, 'out': raw});
          final fromRate = (got?['rate'] as num?)?.toInt() ?? rate;
          final channels = (got?['channels'] as num?)?.toInt() ?? 1;
          await runAside(() => toMono48k(raw, pcm, fromRate: fromRate, channels: channels));
          try {
            File(raw).deleteSync();
          } catch (_) {}
        }
        _pcm.add(pcm);
        _set(opening: (i + 1) / keys.length * 0.8);
      }
      final paths = List.of(_pcm);
      final waves = await runAside(() => [for (final p in paths) waveform(p)]);
      meter.load({for (var i = 0; i < keys.length; i++) keys[i]: waves[i]});
      length = _pcm.fold<int>(0, (n, p) => math.max(n, File(p).lengthSync() ~/ 2));
      // A WAV of each beside its samples, for its player.
      for (final p in _pcm) {
        final wav = p.replaceAll(RegExp(r'\.pcm$'), '.wav');
        if (!File(wav).existsSync() || File(wav).lengthSync() != File(p).lengthSync() + 44) await runAside(() => wrapWav(p, wav));
        final player = _VoicePlayer.make();
        await player.open(wav);
        _players.add(player);
        _readers.add(File(p).openSync());
      }
      if (_disposed) {
        _drop();
        return;
      }
      _applyGains();
      _readLevels();
      _set(opening: null);
    } catch (e) {
      debugPrint('recording playback: $e');
      if (_disposed) _drop();
      _set(opening: null, error: e is StateError ? e.message : 'This recording couldn\'t be opened ($e).');
    }
  }

  /// How far opening has come (null: over), and why it failed where it did; the screen is told.
  void _set({double? opening, String? error}) {
    if (_disposed) return;
    this.opening = opening;
    this.error = error ?? this.error;
    notifyListeners();
  }

  /// Starts every voice's player together, from the start again where the playhead is at the end.
  Future<void> play() async {
    if (!ready || playing) return;
    if (position >= length) await seek(0);
    playing = true;
    await Future.wait([for (final p in _players) p.play()]);
    _clock ??= Timer.periodic(const Duration(milliseconds: 40), (_) => _follow());
    notifyListeners();
  }

  Future<void> pause() async {
    if (!playing) return;
    playing = false;
    await Future.wait([for (final p in _players) p.pause()]);
    _clock?.cancel();
    _clock = null;
    position = _players.isEmpty ? position : _players.first.position.inMicroseconds * rate ~/ 1000000;
    _readLevels();
    notifyListeners();
  }

  Future<void> toggle() => playing ? pause() : play();

  /// Moves the playhead to [second].
  Future<void> seek(double second) async {
    if (!ready) return;
    position = (second.clamp(0.0, seconds) * rate).round();
    final to = Duration(microseconds: position * 1000000 ~/ rate);
    await Future.wait([for (final p in _players) p.seek(to)]);
    _readLevels();
    notifyListeners();
  }

  /// While playing: the playhead from the first voice's player, the others kept within a twentieth of a second of it,
  /// and the meters at the playhead.
  void _follow() {
    if (_players.isEmpty || !playing) return;
    final lead = _players.first.position;
    position = math.min(length, lead.inMicroseconds * rate ~/ 1000000);
    // Once a second (25 ticks of 40 ms): a voice that has drifted from the first is moved back to it.
    if (++_tick % 25 == 0) {
      for (final p in _players.skip(1)) {
        if ((p.position - lead).abs() > const Duration(milliseconds: 50)) unawaited(p.seek(lead));
      }
    }
    // The end: the playhead within a fiftieth of a second of it and the first player stopped by itself.
    if (position >= length - rate ~/ 50 && !_players.first.isPlaying) {
      playing = false;
      _clock?.cancel();
      _clock = null;
    }
    _readLevels();
    notifyListeners();
  }

  /// Each voice's level at the playhead: the loudest sample and the average power of the twentieth of a second there.
  void _readLevels() {
    final now = <String, ({double peak, double rms})>{};
    for (var i = 0; i < _readers.length; i++) {
      now[keys[i]] = levelAt(_readers[i], position);
    }
    meter.at(now);
  }

  @override
  void setFader(String key, double value) {
    mix.setFader(key, value, position);
    _applyGains();
  }

  @override
  void setMuted(String key, bool on) {
    mix.setMuted(key, on, position, among: keys);
    _applyGains();
  }

  @override
  void setSolo(String key, bool on) {
    mix.setSolo(key, on, position, among: keys);
    _applyGains();
  }

  /// Sets each player as loud as the mixer has its voice now.
  void _applyGains() {
    for (var i = 0; i < _players.length; i++) {
      unawaited(_players[i].setGain(mix.gain(keys[i])));
    }
  }

  /// Saving: true while the new recording is being made.
  bool saving = false;

  /// Makes a new recording beside this one: everyone mixed as the faders, mutes and solos stand now, and each voice's
  /// own track as it was. The recording made, kept on this device.
  Future<Recording> save() async {
    if (!ready) throw StateError('The recording isn\'t open yet.');
    saving = true;
    notifyListeners();
    try {
      final id = 'rec${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
      final work = Directory('${folderFor(recording).path}/save-$id')..createSync(recursive: true);
      final mixed = '${work.path}/mix.pcm';
      final paths = List.of(_pcm);
      final gains = [
        for (final k in keys) mix.gain(k) == 1 ? const <GainPoint>[] : [(sample: 0, gain: mix.gain(k))],
      ];
      await runAside(() => mixPcm(paths, mixed, gains: gains));
      final out = '${CallRecorder.folder().path}/$id.mp4';
      await CallRecorder.makeMp4([mixed, ...paths], out, ['Everyone', ...recording.people], work: work.path);
      try {
        work.deleteSync(recursive: true);
      } catch (_) {}
      final r = Recording(
        id: id,
        path: out,
        space: recording.space,
        at: recording.at,
        // One opened from a file ([recordingIn]) says no length: it is as long as its voices are.
        seconds: recording.seconds > 0 ? recording.seconds : seconds.round(),
        people: recording.people,
        by: recording.by,
        seed: recording.seed,
        markers: recording.markers,
        mixedFrom: recording.id,
      );
      CallRecorder.instance.keep(r);
      return r;
    } finally {
      saving = false;
      if (!_disposed) notifyListeners();
      // Closed while it saved: what [dispose] left for this to finish with.
      if (_disposed) _drop();
    }
  }

  /// Deletes the voices decoded for a recording that was only [passing].
  void _drop() {
    if (!passing || saving) return;
    try {
      folderFor(recording).deleteSync(recursive: true);
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _clock?.cancel();
    for (final r in _readers) {
      try {
        r.closeSync();
      } catch (_) {}
    }
    // Once the players have let go of their files (Windows deletes none that is open).
    unawaited(Future.wait([for (final p in _players) p.dispose().catchError((Object _) {})]).whenComplete(_drop));
    meter.dispose();
    mix.dispose();
    super.dispose();
  }
}

/// One voice's player: media_kit (libmpv) on Android, the Mac and Windows, the video_player package (AVFoundation) on
/// the iPhone, as the app's video player has them (lib/ui/video_engine.dart).
abstract class _VoicePlayer {
  static _VoicePlayer make() => !kIsWeb && PlatformInfo.isIOS ? _AvVoice() : _MpvVoice();

  Future<void> open(String path);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration to);

  /// 0 silent, 1 as recorded, up to RecordingMix.most (the iPhone's player goes no louder than as recorded).
  Future<void> setGain(double gain);
  Duration get position;
  bool get isPlaying;
  Future<void> dispose();
}

/// A voice played by media_kit.
class _MpvVoice implements _VoicePlayer {
  mk.Player? _player;

  @override
  Future<void> open(String path) async {
    mk.MediaKit.ensureInitialized();
    final p = _player = mk.Player();
    // Up to twice as loud, as a fader goes (mpv's own most is 130%). Not in a browser (mpv_property.dart).
    await setMpvProperty(p, 'volume-max', '${(RecordingMix.most * 100).round()}');
    await p.open(mk.Media(path), play: false);
  }

  @override
  Future<void> play() async => _player?.play();
  @override
  Future<void> pause() async => _player?.pause();
  @override
  Future<void> seek(Duration to) async => _player?.seek(to);
  @override
  Future<void> setGain(double gain) async => _player?.setVolume((gain * 100).clamp(0, RecordingMix.most * 100).toDouble());
  @override
  Duration get position => _player?.state.position ?? Duration.zero;
  @override
  bool get isPlaying => _player?.state.playing ?? false;
  @override
  Future<void> dispose() async {
    final p = _player;
    _player = null;
    await p?.dispose();
  }
}

/// A voice played by video_player, on the iPhone.
class _AvVoice implements _VoicePlayer {
  VideoPlayerController? _c;

  @override
  Future<void> open(String path) async {
    final c = _c = VideoPlayerController.file(File(path));
    await c.initialize();
  }

  @override
  Future<void> play() async => _c?.play();
  @override
  Future<void> pause() async => _c?.pause();
  @override
  Future<void> seek(Duration to) async => _c?.seekTo(to);
  @override
  Future<void> setGain(double gain) async => _c?.setVolume(gain.clamp(0.0, 1.0));
  @override
  Duration get position => _c?.value.position ?? Duration.zero;
  @override
  bool get isPlaying => _c?.value.isPlaying ?? false;
  @override
  Future<void> dispose() async {
    final c = _c;
    _c = null;
    await c?.dispose();
  }
}

/// [raw] (16-bit samples at [fromRate], [channels] interleaved) as 48 kHz mono 16-bit samples in [out]: the channels
/// averaged, and the rate changed by taking the nearest sample (a recording is made at 48 kHz mono, so this is a copy
/// wherever the decoder gives back what was made).
void toMono48k(String raw, String out, {required int fromRate, required int channels}) {
  final ch = math.max(1, channels);
  if (fromRate == RecordingPlayback.rate && ch == 1) {
    File(raw).copySync(out);
    return;
  }
  final src = ByteData.sublistView(File(raw).readAsBytesSync());
  final frames = src.lengthInBytes ~/ (2 * ch);
  final n = frames * RecordingPlayback.rate ~/ math.max(1, fromRate);
  final dst = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    final at = math.min(frames - 1, i * fromRate ~/ RecordingPlayback.rate);
    var v = 0;
    for (var c = 0; c < ch; c++) {
      v += src.getInt16((at * ch + c) * 2, Endian.little);
    }
    dst.setInt16(i * 2, v ~/ ch, Endian.little);
  }
  File(out).writeAsBytesSync(dst.buffer.asUint8List());
}

/// The waveform of [pcm] (48 kHz mono 16-bit) as the live recording draws it: the loudest sample of each tenth of a
/// second, 0 to 1.
List<double> waveform(String pcm) {
  final d = ByteData.sublistView(File(pcm).readAsBytesSync());
  final n = d.lengthInBytes ~/ 2;
  const step = RecordingMeter.step;
  final out = <double>[];
  for (var at = 0; at < n; at += step) {
    var peak = 0;
    final end = math.min(n, at + step);
    for (var i = at; i < end; i++) {
      final v = d.getInt16(i * 2, Endian.little).abs();
      if (v > peak) peak = v;
    }
    out.add(peak / 32768);
  }
  return out;
}

/// [pcm] (48 kHz mono 16-bit samples) as a WAV file at [wav], for a player.
void wrapWav(String pcm, String wav) {
  final data = File(pcm).readAsBytesSync();
  final h = ByteData(44);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      h.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  // The 44-byte header of a plain PCM WAV: format 1, one channel, 48 kHz, 16 bits a sample.
  tag(0, 'RIFF');
  h.setUint32(4, 36 + data.length, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, 1, Endian.little);
  h.setUint16(22, 1, Endian.little);
  h.setUint32(24, RecordingPlayback.rate, Endian.little);
  h.setUint32(28, RecordingPlayback.rate * 2, Endian.little);
  h.setUint16(32, 2, Endian.little);
  h.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  h.setUint32(40, data.length, Endian.little);
  final sink = File(wav).openSync(mode: FileMode.write);
  try {
    sink.writeFromSync(h.buffer.asUint8List());
    sink.writeFromSync(data);
  } finally {
    sink.closeSync();
  }
}

/// The level of [file] (48 kHz mono 16-bit samples) at [sample]: the loudest sample and the average power of the
/// twentieth of a second there, both 0 to 1; silence past its end.
({double peak, double rms}) levelAt(RandomAccessFile file, int sample) {
  const window = RecordingMeter.window;
  final from = math.max(0, sample - window ~/ 2) * 2;
  final length = file.lengthSync();
  if (from >= length) return (peak: 0, rms: 0);
  file.setPositionSync(from);
  final bytes = file.readSync(math.min(window * 2, length - from));
  final d = ByteData.sublistView(bytes);
  final n = bytes.length ~/ 2;
  if (n == 0) return (peak: 0, rms: 0);
  var peak = 0;
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    final v = d.getInt16(i * 2, Endian.little);
    if (v.abs() > peak) peak = v.abs();
    sum += v * v;
  }
  return (peak: peak / 32768, rms: math.sqrt(sum / n) / 32768);
}
