/// Recording a call (Matt, 2026-11-19: "I'd like to have a "record call" plugin where it records the call to an MP4
/// with multiple named audio tracks"): one MP4 per recording, its first track everyone mixed (what a player plays by
/// itself), then one track per person, each named for them.
///
/// **Whose voice.** A call is a mesh, so each other person's sound already comes to this device on its own; the native
/// half (android CallRecorder.kt, macos and ios CallRecorder.swift, windows/runner/call_recorder.cpp) taps it after WebRTC has decoded it, before this
/// device's volume for them. Only someone whose own device said yes to this recording is tapped ('ry' in their state,
/// VoiceSession): an older build, the browser page or the Discord bridge can't say yes and is never recorded. This
/// device's own voice is in it as sent (after the noise removal), silence while muted.
///
/// **Everyone is told.** The recording's id goes in this device's state ('r'), so every member's app shows that the
/// call is being recorded and asks whether their voice may be in it; a line in the space's chat says it too, for the
/// builds that show nothing else.
///
/// **On the device.** While the call runs each voice goes to a file of its own, kept in step with the others by the
/// clock (silence where someone came late, left or dropped out), so a crash loses only the file at the end. Stopping
/// mixes them, has the platform encode each as AAC into one MP4, and names the tracks (lib/voice/mp4_names.dart). The
/// recording stays on the device ([CallRecorder.folder]) until its maker shares it.
///
/// **With video** (GMFB-42, lib/voice/recording_video.dart), on a Mac or a Windows PC, where its maker chose so at the start: one track
/// of video after the voices, the cameras and shared screens of those who said yes to voice and video. The native half
/// encodes it to a file of its own while the call runs (the frames can't be kept as they are, as the voices are), and
/// the stop copies it into the MP4 beside the voices without encoding it again.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../platform_info.dart';
import '../aside.dart';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../desktop/store.dart' show DeskStore;
import 'channels.dart';
import '../plugins/record_call.dart' show RecordCallPlugin;
import '../plugins/scribe.dart' show ScribePlugin;
import 'mp4_merge.dart';
import 'mp4_names.dart';
import 'plugin_note.dart';
import 'recording_video.dart';
import 'scribe.dart';
import 'voice.dart';

/// One recording kept on this device.
@immutable
class Recording {
  const Recording({required this.id, required this.path, required this.space, required this.at, required this.seconds, required this.people, this.by = '', this.seed = '', this.markers = const [], this.mixedFrom, this.video = false});

  final String id;

  /// The MP4.
  final String path;

  /// The space's name, as it was.
  final String space;
  final DateTime at;
  final int seconds;

  /// Whose voices are in it, by name, in the file's track order (after the mix).
  final List<String> people;

  /// Who made it.
  final String by;

  /// The space's seed, to send it to that space's chat.
  final String seed;

  /// The moments its maker marked while recording, in seconds from its start.
  final List<double> markers;

  /// The recording this one was mixed again from in the mixer (lib/voice/recording_playback.dart); null for one made
  /// in a call.
  final String? mixedFrom;

  /// It has a track of video after its voices: the call's cameras and shared screens (GMFB-42).
  final bool video;

  Map<String, Object?> toJson() => {'id': id, 'path': path, 'space': space, 'at': at.millisecondsSinceEpoch, 'seconds': seconds, 'people': people, 'by': by, 'seed': seed, if (markers.isNotEmpty) 'markers': markers, 'from': ?mixedFrom, if (video) 'video': true};

  static Recording? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['path'] is! String || j['at'] is! int) return null;
    return Recording(
      id: j['id'] as String,
      path: j['path'] as String,
      space: '${j['space'] ?? ''}',
      at: DateTime.fromMillisecondsSinceEpoch(j['at'] as int),
      seconds: (j['seconds'] as num?)?.toInt() ?? 0,
      people: [for (final p in (j['people'] as List? ?? const [])) '$p'],
      by: '${j['by'] ?? ''}',
      seed: '${j['seed'] ?? ''}',
      markers: [for (final m in (j['markers'] as List? ?? const [])) if (m is num) m.toDouble()],
      mixedFrom: j['from'] is String ? j['from'] as String : null,
      video: j['video'] == true,
    );
  }
}

/// What is being recorded now.
class _Taking {
  _Taking(this.id, this.dir, this.space, this.seed, this.started);
  final String id;
  final String seed;
  final String dir;
  final String space;
  final DateTime started;

  /// Each voice's file key (`me`, or a member's id) and the name to give its track.
  final Map<String, String> names = {};

  /// The members tapped now.
  final Set<String> tapped = {};

  /// The track each is tapped on: a connection started over (through the relay, or again directly) brings their
  /// sound on a new one, which is tapped in its place.
  final Map<String, String> trackOf = {};

  /// The moments marked, in seconds from the start.
  final List<double> markers = [];

  /// It takes video too (GMFB-42): the native half is encoding the call's picture beside the voices.
  bool video = false;

  /// The picture's file while it is made: video alone, put into the MP4 at the stop. An MP4 on Windows, where Media
  /// Foundation's writer goes by the name's ending and lib/voice/mp4_merge.dart reads it.
  String get videoPart => !kIsWeb && PlatformInfo.isWindows ? '$dir/video.mp4' : '$dir/video.mov';

  /// What the native half was last told to draw ([VideoLayout.signature]), and the telling still on its way.
  String pictureSaid = '';
  Future<void> picturing = Future.value();
}

/// How loud each voice is as it is recorded, a tenth of a second at a time: read from the files the native half
/// writes (48 kHz mono 16-bit, kept in step by the clock), so the recording's panel can draw each track's waveform as
/// it grows (lib/ui/recording_float.dart; Matt, 2026-11-20: "show the different audio tracks being recorded and the
/// sound waves from each audio track").
class RecordingMeter extends ChangeNotifier {
  /// Samples in one step of the waveform: a tenth of a second.
  static const step = 4800;

  /// Steps a second.
  static const perSecond = 10;

  /// Samples in what a meter shows as "now": a twentieth of a second, so a meter moves as the voice does.
  static const window = 2400;

  /// At or over this a sample is at the top of what the file holds: the voice is clipping.
  static const clipAt = 0.985;

  /// Each voice's loudness by step, 0 to 1 (the loudest sample in it), from the recording's start.
  final Map<String, List<double>> levels = {};

  /// How many bytes of each voice's file have gone into [levels] already.
  final Map<String, int> _read = {};

  /// Each voice now (Matt, 2026-11-20: "show audio tracks being recorded in real time with meters and whatnot as well
  /// as voice level changing"): the loudest sample and the average power (RMS) of the newest twentieth of a second
  /// written, both 0 to 1 as the file holds them, before any fader. Zero for a voice that has stopped being written.
  final Map<String, ({double peak, double rms})> now = {};

  /// Each file's length at the last look: one that hasn't grown since has stopped being written.
  final Map<String, int> _length = {};

  /// Voices that have clipped since the lamp was last cleared ([clearClip]).
  final Set<String> clipped = {};

  /// Forgets everything read, for a new recording or after one stops.
  void clear() {
    levels.clear();
    _read.clear();
    now.clear();
    _length.clear();
    clipped.clear();
    notifyListeners();
  }

  /// Puts a voice's clip lamp out (all of them where [key] is null).
  void clearClip([String? key]) {
    if (key == null ? clipped.isEmpty : !clipped.remove(key)) return;
    if (key == null) clipped.clear();
    notifyListeners();
  }

  /// Reads what has been written to each of [files] (a voice's key and its file) since the last look: whole steps
  /// for the waveform, and the newest [window] for the meters.
  void read(Map<String, String> files) {
    var any = false;
    for (final e in files.entries) {
      final f = File(e.value);
      if (!f.existsSync()) continue;
      final length = f.lengthSync();
      final from = _read[e.key] ?? 0;
      final grew = length != (_length[e.key] ?? -1);
      _length[e.key] = length;
      RandomAccessFile? raf;
      try {
        // Now: the newest window, or silence where nothing has been written since the last look.
        final was = now[e.key];
        if (grew && length >= 2) {
          raf = f.openSync();
          // Two bytes a sample; `& ~1` keeps the read on a whole sample where the file ends mid-write.
          final take = (length < window * 2 ? length : window * 2) & ~1;
          raf.setPositionSync((length - take) & ~1);
          final d = ByteData.sublistView(raf.readSync(take));
          var peak = 0;
          var sum = 0.0;
          final n = d.lengthInBytes ~/ 2;
          for (var i = 0; i < n; i++) {
            final v = d.getInt16(i * 2, Endian.little);
            final a = v.abs();
            if (a > peak) peak = a;
            sum += v * v;
          }
          final level = (peak: peak / 32768, rms: n == 0 ? 0.0 : math.sqrt(sum / n) / 32768);
          now[e.key] = level;
          if (level.peak >= clipAt && clipped.add(e.key)) any = true;
          if (was != level) any = true;
        } else if (was != null && (was.peak != 0 || was.rms != 0)) {
          now[e.key] = (peak: 0, rms: 0);
          any = true;
        }
        // Whole steps only: what is past the last whole one is read next time.
        final whole = ((length - from) ~/ (step * 2)) * step * 2;
        if (whole <= 0) continue;
        raf ??= f.openSync();
        raf.setPositionSync(from);
        final bytes = raf.readSync(whole);
        final d = ByteData.sublistView(bytes);
        final out = levels.putIfAbsent(e.key, () => <double>[]);
        for (var at = 0; at + step * 2 <= bytes.length; at += step * 2) {
          var peak = 0;
          for (var i = at; i < at + step * 2; i += 2) {
            final v = d.getInt16(i, Endian.little).abs();
            if (v > peak) peak = v;
          }
          out.add(peak / 32768);
        }
        _read[e.key] = from + bytes.length;
        any = true;
      } finally {
        raf?.closeSync();
      }
    }
    if (any) notifyListeners();
  }

  /// A recording opened again (lib/voice/recording_playback.dart): every voice's whole waveform at once.
  void load(Map<String, List<double>> all) {
    clear();
    levels.addAll(all);
    notifyListeners();
  }

  /// Each voice's level at the playhead of a recording opened again; a voice at the top lights its clip lamp.
  void at(Map<String, ({double peak, double rms})> given) {
    var any = false;
    for (final e in given.entries) {
      if (now[e.key] != e.value) any = true;
      now[e.key] = e.value;
      if (e.value.peak >= clipAt && clipped.add(e.key)) any = true;
    }
    if (any) notifyListeners();
  }

  /// [levels] as given, for a picture or a test; [live] is each voice now where it is not its last step.
  @visibleForTesting
  void seed(Map<String, List<double>> given, {Map<String, ({double peak, double rms})>? live, Set<String> clipping = const {}}) {
    levels
      ..clear()
      ..addAll(given);
    now
      ..clear()
      ..addAll(live ?? {for (final e in given.entries) e.key: (peak: e.value.isEmpty ? 0.0 : e.value.last, rms: e.value.isEmpty ? 0.0 : e.value.last * 0.6)});
    clipped
      ..clear()
      ..addAll(clipping);
    notifyListeners();
  }
}

/// A point where a voice's loudness in the mix changes: from [sample] of the recording on it is [gain] (0 silent, 1
/// as recorded, up to [RecordingMix.most]).
typedef GainPoint = ({int sample, double gain});

/// The recording's mixer (Matt, 2026-11-20: "voice level changing and more"): how loud each voice is in the track of
/// everyone mixed, its fader, and whether it is muted or soloed there. Moved while recording, the mix follows as it
/// was moved: each change is kept with the moment it was made and played back into the mix when the recording stops
/// ([mixPcm]). Each person's own track is left as it was recorded, so the recording can always be mixed again.
class RecordingMix extends ChangeNotifier {
  /// The most a fader gives: twice as loud, +6 dB.
  static const most = 2.0;

  final Map<String, double> _fader = {};
  final Set<String> _muted = {};
  final Set<String> _solo = {};

  /// Each voice's changes of loudness in the mix, in order of sample.
  final Map<String, List<GainPoint>> _points = {};

  /// Goes up with every change, for whoever keeps something worked out from the points.
  int revision = 0;

  /// How loud [key] was in the mix at [sample] of the recording.
  double gainAt(String key, int sample) {
    var g = 1.0;
    for (final p in _points[key] ?? const <GainPoint>[]) {
      if (p.sample > sample) break;
      g = p.gain;
    }
    return g;
  }

  /// A voice's fader, 0 to [most]; 1 where it has not been moved.
  double fader(String key) => _fader[key] ?? 1;
  bool muted(String key) => _muted.contains(key);
  bool soloed(String key) => _solo.contains(key);
  bool get anySolo => _solo.isNotEmpty;

  /// How loud a voice is in the mix now: its fader, or nothing while it is muted or another voice is soloed.
  double gain(String key) => _muted.contains(key) || (_solo.isNotEmpty && !_solo.contains(key)) ? 0 : fader(key);

  /// Every change made to [key]'s loudness in the mix, in order; empty where it was never other than as recorded.
  List<GainPoint> points(String key) => List.unmodifiable(_points[key] ?? const <GainPoint>[]);

  /// Back to every voice as recorded, with no changes kept.
  void clear() {
    _fader.clear();
    _muted.clear();
    _solo.clear();
    _points.clear();
    revision++;
    notifyListeners();
  }

  /// Sets [key]'s fader at [sample] of the recording.
  void setFader(String key, double value, int sample, {Iterable<String> among = const []}) {
    final v = value.clamp(0.0, most).toDouble();
    if (v == fader(key)) return;
    _change(sample, [key, ...among], () => v == 1 ? _fader.remove(key) : _fader[key] = v);
  }

  /// Mutes or unmutes [key] in the mix at [sample].
  void setMuted(String key, bool on, int sample, {Iterable<String> among = const []}) {
    if (on == muted(key)) return;
    _change(sample, [key, ...among], () => on ? _muted.add(key) : _muted.remove(key));
  }

  /// Solos [key] at [sample]: while any voice is soloed only the soloed are in the mix, so every one of [among] (the
  /// voices there are) may change.
  void setSolo(String key, bool on, int sample, {Iterable<String> among = const []}) {
    if (on == soloed(key)) return;
    _change(sample, [key, ...among], () => on ? _solo.add(key) : _solo.remove(key));
  }

  /// Makes a change and writes down each of [keys] whose loudness in the mix it moved.
  void _change(int sample, Iterable<String> keys, void Function() make) {
    final all = keys.toSet();
    final before = {for (final k in all) k: gain(k)};
    make();
    for (final k in all) {
      final g = gain(k);
      if (g == before[k]) continue;
      final list = _points.putIfAbsent(k, () => <GainPoint>[]);
      final at = sample < 0 ? 0 : sample;
      // A fader dragged makes many changes in a moment: one at the same place replaces the last.
      if (list.isNotEmpty && list.last.sample >= at) {
        list[list.length - 1] = (sample: list.last.sample, gain: g);
      } else {
        list.add((sample: at, gain: g));
      }
    }
    revision++;
    notifyListeners();
  }
}

/// What the recording's timeline and mixer draw from and move (lib/ui/recording_float.dart): the recording being made
/// ([CallRecorder]), or one kept on this device opened again to play and mix ([RecordingPlayback]).
abstract interface class RecordingDesk implements Listenable {
  /// Each voice's waveform, and its level now (live: as it is written; played: at the playhead).
  RecordingMeter get meter;

  /// Each voice's fader, mute and solo in the mix.
  RecordingMix get mix;

  /// The voices, in the file's order after the mix.
  List<({String key, String name, bool live})> get tracks;

  /// The moments marked, in seconds from the start.
  List<double> get markers;

  /// Moves the voice [key]'s fader, mutes it, or solos it, from now on in the mix.
  void setFader(String key, double value);
  void setMuted(String key, bool on);
  void setSolo(String key, bool on);
}

class CallRecorder extends ChangeNotifier implements RecordingDesk {
  CallRecorder._();
  static final CallRecorder instance = CallRecorder._();

  /// Recording as given, for a picture of the recording's panel: [names] by key ('me' first), those in [left] no
  /// longer taken. It takes nothing and writes nothing.
  @visibleForTesting
  CallRecorder.standing({required Map<String, String> names, required DateTime since, Set<String> left = const {}, List<double> markers = const []}) {
    final t = _now = _Taking('rec-standing', Directory.systemTemp.path, 'general', 'standing', since);
    t.names.addAll(names);
    t.tapped.addAll(names.keys.where((k) => k != 'me' && !left.contains(k)));
    t.markers.addAll(markers);
  }

  /// For a test: the standing recording over, as a Stop or the call's end leaves it.
  @visibleForTesting
  void endForTest() {
    _now = null;
    notifyListeners();
  }

  static const _channel = MethodChannel('ghost/recorder');

  /// Whether this platform records calls: a phone, a Mac or iPhone, and Windows (windows/runner/call_recorder.cpp;
  /// Matt, 2026-11-21: "my friend is not able to see plugins added for recording calls on his pc"); not a browser.
  static bool get supported => !kIsWeb && (PlatformInfo.isAndroid || PlatformInfo.isMacOS || PlatformInfo.isIOS || PlatformInfo.isWindows);

  /// Whether this device can put the call's cameras and shared screens in a recording: a Mac (GMFB-42,
  /// lib/voice/recording_video.dart). Everywhere else a recording is the voices, as before.
  static bool get videoSupported => supported && RecordingVideo.supported;

  /// Whether the recording being made takes video.
  bool get recordingVideo => _now?.video ?? false;

  _Taking? _now;

  /// Each voice's loudness as it is recorded (RecordingMeter), read every tenth of a second while recording.
  @override
  final RecordingMeter meter = RecordingMeter();
  Timer? _metering;

  /// The recording's mixer: each voice's fader, mute and solo in the mix (RecordingMix).
  @override
  final RecordingMix mix = RecordingMix();

  /// Where the recording is now, in samples from its start (the voices' files are kept in step by the clock).
  int get position {
    final t = _now;
    // 48 samples a millisecond (48 kHz).
    return t == null ? 0 : (DateTime.now().difference(t.started).inMicroseconds * 48 ~/ 1000);
  }

  /// The keys of the voices there are, for a solo, which moves every one of them.
  Iterable<String> get _keys => _now?.names.keys ?? const <String>[];

  @override
  void setFader(String key, double value) => mix.setFader(key, value, position);
  @override
  void setMuted(String key, bool on) => mix.setMuted(key, on, position, among: _keys);
  @override
  void setSolo(String key, bool on) => mix.setSolo(key, on, position, among: _keys);

  /// The moments marked so far, in seconds from the start.
  @override
  List<double> get markers => List.unmodifiable(_now?.markers ?? const <double>[]);

  /// Marks this moment of the recording, to find again afterwards; the second marked, or null where nothing records.
  double? mark() {
    final t = _now;
    if (t == null) return null;
    final at = DateTime.now().difference(t.started).inMilliseconds / 1000;
    t.markers.add(at);
    notifyListeners();
    return at;
  }

  /// The tracks being recorded, 'me' first: each voice's key, its name, and whether it is being taken now (false for
  /// someone who left or took back their yes; their track keeps what it has).
  @override
  List<({String key, String name, bool live})> get tracks {
    final t = _now;
    if (t == null) return const [];
    return [
      for (final k in t.names.keys)
        if (k == 'me' || t.tapped.contains(k) || meter.levels.containsKey(k)) (key: k, name: t.names[k]!, live: k == 'me' || t.tapped.contains(k)),
    ];
  }

  /// Each voice's key and the raw sound file the native half writes for it.
  Map<String, String> _files(_Taking t) => {for (final k in t.names.keys) k: '${t.dir}/${_safe(k)}.pcm'};

  /// Being made into a file after stopping.
  bool finishing = false;

  /// Where the last recording went beyond this device, or why it didn't: a circle's Files space (Record call's choice,
  /// lib/plugins/record_call.dart); null outside a circle.
  String? savedTo;

  /// The recording being made now, by its id.
  String? get recording => _now?.id;
  DateTime? get since => _now?.started;

  /// Whose voices are being recorded now, by name ('You' first).
  List<String> get recordedNames => [for (final k in _now?.names.keys ?? const <String>[]) if (k == 'me' || (_now?.tapped.contains(k) ?? false)) _now!.names[k]!];

  /// For a test: where recordings are kept instead, so one that records writes nothing in the app's own folder.
  @visibleForTesting
  static Directory? folderForTest;

  /// Where recordings are kept: the app's own folder (a phone's is cleared only with the app).
  static Directory folder() {
    final given = folderForTest;
    if (given != null) return given;
    if (!kIsWeb && PlatformInfo.isAndroid) return Directory('${Directory.systemTemp.parent.path}/files/recordings');
    return Directory('${DeskStore.defaultDir().path}/recordings');
  }

  final List<Recording> _kept = [];
  bool _read = false;

  /// The recordings kept here, the newest first.
  List<Recording> get kept {
    _readKept();
    return List.unmodifiable(_kept);
  }

  /// The list of kept recordings, as JSON in the recordings folder.
  File get _index => File('${folder().path}/recordings.json');

  /// Reads the list once, leaving out any recording whose MP4 is gone.
  void _readKept() {
    if (_read) return;
    _read = true;
    try {
      final list = jsonDecode(_index.readAsStringSync()) as List;
      _kept
        ..clear()
        ..addAll([for (final j in list) ?Recording.fromJson(j)].where((r) => File(r.path).existsSync()));
    } catch (_) {}
  }

  void _writeKept() {
    try {
      folder().createSync(recursive: true);
      _index.writeAsStringSync(jsonEncode([for (final r in _kept) r.toJson()]));
    } catch (_) {}
  }

  /// Deletes [r] from this device.
  void delete(Recording r) {
    CallScribe.instance.forget(r);
    _readKept();
    _kept.removeWhere((k) => k.id == r.id);
    try {
      File(r.path).deleteSync();
    } catch (_) {}
    // Its voices as the mixer decoded them (lib/voice/recording_playback.dart).
    try {
      Directory('${folder().path}/opened/${r.id}').deleteSync(recursive: true);
    } catch (_) {}
    _writeKept();
    notifyListeners();
  }

  StreamSubscription<void>? _watch;

  /// Starts recording the call [Voice] is in; the reason in words where it can't. [video]: with the call's cameras
  /// and shared screens too, where this device can ([videoSupported]) and the picture's file can be begun; otherwise
  /// the voices alone, and [recordingVideo] says which it was.
  Future<String?> start({bool video = false}) async {
    final v = Voice.instance;
    final s = v.session;
    if (s == null) return 'There is no call to record.';
    if (!supported) return 'Calls can\'t be recorded on this device yet.';
    if (_now != null || finishing) return 'A recording is already being made.';
    final id = _hexId();
    final dir = Directory('${folder().path}/$id.parts');
    try {
      dir.createSync(recursive: true);
      await _channel.invokeMethod('start', {'mic': '${dir.path}/me.pcm', 'muted': s.muted || s.deafened});
    } catch (e) {
      return 'The recording couldn\'t start: $e';
    }
    final t = _now = _Taking(id, dir.path, s.channel.name, s.channel.seed, DateTime.now());
    t.names['me'] = s.name.isEmpty ? 'You' : s.name;
    // The picture's file begun before anyone is asked: what they are asked ("voice and video", or the voice alone) is
    // what is then taken, for the recording's whole length.
    if (video && videoSupported) {
      try {
        t.video = await _channel.invokeMethod<bool>('video.start', {'path': t.videoPart, 'width': RecordingVideo.width, 'height': RecordingVideo.height, 'fps': RecordingVideo.fps, 'bitrate': RecordingVideo.bitrate}) ?? false;
      } catch (e) {
        debugPrint('recorder: no video: $e');
      }
    }
    s.setRecording(id, video: t.video);
    s.answerRecording(id, true);
    // A line every build shows, the browser page and older apps among them.
    // With Record call's note, which draws it as a card with its icon (lib/plugins/record_call.dart); the words are what
    // a build without it shows.
    v.hangoutFor(s.channel)?.sendWith(
      text: t.video
          ? '🔴 ${t.names['me']} started recording this call, with video. Only people who say yes are in it.'
          : '🔴 ${t.names['me']} started recording this call. Only the voices of people who say yes are in it.',
      note: PluginChatNote('recordcall', 'started', {'by': t.names['me']!, if (t.video) 'video': '1'}),
    );
    _watch = _changes(s).listen((_) => _follow(s));
    _follow(s);
    meter.clear();
    mix.clear();
    // Twenty times a second: the meters move as the voices do.
    _metering = Timer.periodic(const Duration(milliseconds: 50), (_) {
      final now = _now;
      if (now != null) meter.read(_files(now));
    });
    notifyListeners();
    return null;
  }

  /// Ticks whenever the session changes (someone's answer, mute, coming or going) or someone's sound arrives or goes.
  Stream<void> _changes(VoiceSession s) {
    final c = StreamController<void>();
    void tell() => c.add(null);
    s.addListener(tell);
    final media = s.media;
    final sounds = media is SoundMedia ? (media as SoundMedia).sounds : null;
    sounds?.addListener(tell);
    // And whenever a picture comes, goes or changes, for a recording that draws them (GMFB-42).
    final pictures = media is PictureMedia ? (media as PictureMedia).pictureChanges : null;
    pictures?.addListener(tell);
    c.onCancel = () {
      s.removeListener(tell);
      sounds?.removeListener(tell);
      pictures?.removeListener(tell);
    };
    return c.stream;
  }

  /// Follows once more in a second, where someone's sound was announced before the native half held it.
  Timer? _again;

  /// Taps whoever has said yes and whose sound has come; lets go of whoever has said no or gone; says this device's mute.
  Future<void> _follow(VoiceSession s) async {
    final t = _now;
    if (t == null) return;
    // The call ended or was left: the recording ends with it.
    if (Voice.instance.session != s || !s.joined) {
      unawaited(stop());
      return;
    }
    unawaited(_channel.invokeMethod('muted', {'on': s.muted || s.deafened}).catchError((_) {}));
    // Each one's sound as the call's media says it (GMFB-52: "After a user says include me I expect them to show up in
    // the mixer and their audio to be recorded"). It was looked for in the streams the tiles draw, which have held
    // pictures only since video was mended, so nobody who said yes was ever tapped.
    final media = s.media;
    final sounds = media is SoundMedia ? (media as SoundMedia).sounds.value : const <String, VoiceSound>{};
    for (final m in s.members.values.toList()) {
      final yes = m.agreed.contains(t.id) && !m.declined.contains(t.id);
      final sound = sounds[m.id];
      // Which track on which connection: a connection made again mid-call (VoiceSession mends a broken one) brings
      // their sound under the same track id, and it is the new one that has to be tapped.
      final mark = sound == null ? null : '${sound.link}/${sound.track}';
      // Tapped where they said yes and their sound has come, and again whenever it comes on another track (Matt,
      // 2026-11-21: "recording is only recording my audio and not everyones audio tracks": since calls start through
      // the relay and may start over, a voice's first track can end while the call goes on). The native half keeps
      // writing the same file.
      if (yes && sound != null && (!t.tapped.contains(m.id) || t.trackOf[m.id] != mark)) {
        final id = sound.track;
        t.tapped.add(m.id);
        t.trackOf[m.id] = mark!;
        t.names[m.id] = Voice.instance.nameOf(m.id);
        try {
          final ok = await _channel.invokeMethod<bool>('add', {'key': m.id, 'track': id, 'path': '${t.dir}/${_safe(m.id)}.pcm'});
          // Not found yet (the track is announced before the native side holds it): tried again in a second.
          if (ok == false) {
            if (t.trackOf[m.id] == mark) t.trackOf.remove(m.id);
            _again?.cancel();
            _again = Timer(const Duration(seconds: 1), () => unawaited(_follow(s)));
          }
        } catch (_) {
          t.tapped.remove(m.id);
          t.trackOf.remove(m.id);
        }
      } else if (!yes && t.tapped.contains(m.id)) {
        t.tapped.remove(m.id);
        t.trackOf.remove(m.id);
        unawaited(_channel.invokeMethod('remove', {'key': m.id}).catchError((_) {}));
      }
      if (yes) t.names[m.id] = Voice.instance.nameOf(m.id);
    }
    for (final gone in t.tapped.where((k) => !s.members.containsKey(k)).toList()) {
      t.tapped.remove(gone);
      t.trackOf.remove(gone);
      unawaited(_channel.invokeMethod('remove', {'key': gone}).catchError((_) {}));
    }
    if (t.video) _picture(s, t);
    notifyListeners();
  }

  /// Tells the native half what the recording's picture is made of now, where that has changed: who has a tile, whose
  /// camera or screen may be drawn in it (only with their yes to voice and video), and where each goes
  /// (lib/voice/recording_video.dart). The tiles' backs and names go as a picture painted here.
  void _picture(VoiceSession s, _Taking t) {
    final media = s.media;
    final pictures = media is PictureMedia ? media as PictureMedia : null;
    final layout = RecordingVideo.layout(RecordingVideo.faces(
      recording: t.id,
      myName: t.names['me']!,
      members: s.members.values,
      nameOf: Voice.instance.nameOf,
      own: pictures?.ownPicture,
      pictures: pictures?.pictures ?? const {},
    ));
    final said = layout.signature;
    if (said == t.pictureSaid) return;
    t.pictureSaid = said;
    // One at a time, in order; one that a newer has overtaken while it waited is not sent.
    t.picturing = t.picturing.then((_) async {
      if (_now != t || t.pictureSaid != said) return;
      try {
        final plate = await RecordingVideo.plate(layout);
        if (_now != t) return;
        final missing = await _channel.invokeMethod<Object?>('video.layout', {'plate': plate, 'width': layout.width, 'height': layout.height, 'tiles': layout.toNative()});
        // A track said here before the native half holds it: told again in a second, as a voice's is.
        if (missing is List && missing.isNotEmpty && _now == t && t.pictureSaid == said) {
          t.pictureSaid = '';
          _again?.cancel();
          _again = Timer(const Duration(seconds: 1), () => unawaited(_follow(s)));
        }
      } catch (e) {
        debugPrint('recorder: the picture was not laid out: $e');
      }
    });
  }

  /// Stops the recording and makes its MP4; the recording, or null where nothing could be made.
  Future<Recording?> stop() async {
    final t = _now;
    if (t == null) return null;
    _now = null;
    savedTo = null;
    _metering?.cancel();
    _metering = null;
    meter.clear();
    await _watch?.cancel();
    _watch = null;
    final s = Voice.instance.session;
    if (s != null && s.recording == t.id) s.setRecording(null);
    finishing = true;
    notifyListeners();
    // What the "stopped" card says (lib/plugins/record_call.dart): how long, how many voices, where it went.
    var seconds = DateTime.now().difference(t.started).inSeconds;
    var voices = 0;
    var pictured = false;
    try {
      // The picture's file is closed first, where one was made and has any frames.
      String? picture;
      if (t.video) {
        try {
          await t.picturing;
          final got = await _channel.invokeMethod<Object?>('video.stop');
          if (got is Map && ((got['frames'] as num?)?.toInt() ?? 0) > 0) picture = t.videoPart;
        } catch (e) {
          debugPrint('recorder: the video was not closed: $e');
        }
      }
      final counts = ((await _channel.invokeMethod<Map>('stop')) ?? const {}).map((k, v) => MapEntry('$k', (v as num).toInt()));
      // Every voice that has any sound, 'me' first, in the order they came.
      final keys = [for (final k in t.names.keys) if ((counts[k] ?? 0) > 0) k];
      if (keys.isEmpty) return null;
      final paths = [for (final k in keys) '${t.dir}/${_safe(k)}.pcm'];
      final mix = '${t.dir}/mix.pcm';
      // The mix as its faders, mutes and solos were moved while it recorded; each voice's own track as recorded.
      final moved = [for (final k in keys) this.mix.points(k)];
      await runAside(() => mixPcm(paths, mix, gains: moved));
      final out = '${folder().path}/${t.id}.mp4';
      final names = ['Everyone', for (final k in keys) t.names[k]!];
      pictured = await makeMp4([mix, ...paths], out, names, work: t.dir, video: picture);
      seconds = (counts.values.fold<int>(0, (a, b) => a > b ? a : b) / 48000).round();
      voices = keys.length;
      final r = Recording(id: t.id, path: out, space: t.space, at: t.started, seconds: seconds, people: names.skip(1).toList(), by: t.names['me']!, seed: t.seed, markers: List.of(t.markers), video: pictured);
      _readKept();
      _kept.insert(0, r);
      _writeKept();
      try {
        Directory(t.dir).deleteSync(recursive: true);
      } catch (_) {}
      // Into its circle's Files space, in the folder the circle chose (lib/plugins/record_call.dart).
      try {
        savedTo = RecordCallPlugin.saveInCircle(r);
      } catch (e) {
        savedTo = 'Kept on this device: it couldn\'t be saved to the circle ($e)';
      }
      // Written out at once where Scribe is on for it and says so (lib/plugins/scribe.dart).
      if (ScribePlugin.autoFor(r)) unawaited(CallScribe.instance.transcribe(r));
      return r;
    } catch (e) {
      debugPrint('recorder: $e');
      return null;
    } finally {
      finishing = false;
      mix.clear();
      notifyListeners();
      final room = s == null ? null : Voice.instance.hangoutFor(s.channel);
      room?.sendWith(
        text: '⏹ ${t.names['me']} stopped recording.',
        note: PluginChatNote('recordcall', 'stopped', {
          'by': t.names['me']!,
          'seconds': '$seconds',
          if (voices > 0) 'voices': '$voices',
          if (pictured) 'video': '1',
          'savedTo': ?savedTo,
        }),
      );
    }
  }

  /// Makes [out], an MP4 with a track of AAC for each of [inputs] (48 kHz mono 16-bit files, the mix first), named
  /// [names]; [work] is a folder for what is made on the way. Also what a recording mixed again in the mixer is saved
  /// as (lib/voice/recording_playback.dart).
  ///
  /// [video] is a file of video alone to put in as the last track, as it is (GMFB-42; made on a Mac and on Windows). After the voices, so every voice keeps its place in the file and a reader that counts tracks finds them
  /// where they were. True where the file made has it.
  static Future<bool> makeMp4(List<String> inputs, String out, List<String> names, {required String work, String? video}) async {
    var pictured = false;
    if (!kIsWeb && PlatformInfo.isWindows) {
      // Windows makes each voice an AAC file of its own; they are put together here (lib/voice/mp4_merge.dart).
      final parts = <String>[];
      for (final (i, p) in inputs.indexed) {
        final part = '$work/track$i.m4a';
        await _channel.invokeMethod('encode', {'in': p, 'out': part});
        parts.add(part);
      }
      // The picture's file, where one was made (windows/runner/call_video.cpp), goes in after them as it is.
      pictured = await Mp4Merge.merge(parts, out, video: video);
    } else {
      // With a picture asked for, the answer says whether it went in; without, it is the file's path, as it was.
      final made = await _channel.invokeMethod<Object?>('mux', {'out': out, 'inputs': inputs, 'video': ?video});
      pictured = made is Map && made['video'] == true;
    }
    await Mp4Names.apply(out, names);
    return pictured;
  }

  /// Keeps [r] in the list of recordings on this device, the newest first (a recording mixed again in the mixer).
  void keep(Recording r) {
    _readKept();
    _kept.insert(0, r);
    _writeKept();
    notifyListeners();
  }

  /// A file name for a member's key: their id is hex already; 'me' is 'me'.
  static String _safe(String key) => key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  /// A new recording's id: `rec` and the time now in hex.
  static String _hexId() {
    final r = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    return 'rec$r';
  }
}

/// Mixes [inputs] (48 kHz mono 16-bit files, the shorter ones read as silence past their end) into [out], each voice at
/// its own loudness and the sum held under clipping.
///
/// [gains] gives, for each input in order, the changes made to its loudness while it was recorded (RecordingMix): it
/// is as recorded until its first point, then each point's gain from that sample on, reached over a hundredth of a
/// second so a mute or a fader's move is never a click. An input with no points, or no [gains] at all, is as recorded.
void mixPcm(List<String> inputs, String out, {List<List<GainPoint>>? gains}) {
  final files = [for (final p in inputs) File(p).openSync()];
  final sink = File(out).openSync(mode: FileMode.write);
  // Where each input is in its points, and how loud it is and is heading.
  // Samples a full swing of gain takes: a hundredth of a second.
  const ramp = 480;
  final next = List<int>.filled(inputs.length, 0);
  final at = List<double>.filled(inputs.length, 1);
  final goal = List<double>.filled(inputs.length, 1);
  try {
    const block = 48000; // A second at a time.
    var done = 0;
    while (true) {
      final reads = [for (final f in files) f.readSync(block * 2)];
      final longest = reads.fold<int>(0, (n, b) => b.length > n ? b.length : n);
      if (longest == 0) break;
      final n = longest ~/ 2;
      final sum = Float64List(n);
      for (var f = 0; f < reads.length; f++) {
        final b = reads[f];
        final d = ByteData.sublistView(b);
        final points = gains != null && f < gains.length ? gains[f] : const <GainPoint>[];
        final has = b.length ~/ 2;
        if (points.isEmpty) {
          for (var i = 0; i < has; i++) {
            sum[i] += d.getInt16(i * 2, Endian.little);
          }
          continue;
        }
        var g = at[f], to = goal[f], k = next[f];
        const stepBy = 1 / ramp;
        // Past this input's end too: its points still pass, so a later block starts from the right loudness.
        for (var i = 0; i < n; i++) {
          while (k < points.length && points[k].sample <= done + i) {
            to = points[k].gain;
            k++;
          }
          if (g != to) g = g < to ? math.min(to, g + stepBy * RecordingMix.most) : math.max(to, g - stepBy * RecordingMix.most);
          if (i < has) sum[i] += d.getInt16(i * 2, Endian.little) * g;
        }
        at[f] = g;
        goal[f] = to;
        next[f] = k;
      }
      final o = ByteData(n * 2);
      for (var i = 0; i < n; i++) {
        o.setInt16(i * 2, sum[i].round().clamp(-32768, 32767), Endian.little);
      }
      sink.writeFromSync(o.buffer.asUint8List());
      done += n;
    }
  } finally {
    for (final f in files) {
      f.closeSync();
    }
    sink.closeSync();
  }
}
