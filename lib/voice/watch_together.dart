/// Watching a file together in a call (Matt, 2026-11-19: "watch together"): a video or a song from a Files space,
/// played on every device in the call from its own sealed copy, in step. Nothing is streamed from one device to the
/// others and nothing goes through a server but the file itself, which each device reads from the Files space as it
/// always does (lib/files/file_stream.dart); only what is done with it is said in the call ('wt' in its room).
///
/// - Whoever starts it says the file (as a Files space's entry carries it, with its key, sealed as everything said in
///   the call is) and where it is; each device in the call shows a line to watch it too.
/// - Anyone watching may play, pause or move it: they say where it is and whether it plays, and everyone's player goes
///   there. Whoever started it says where it is every few seconds while it plays, so a late joiner and a slow player
///   catch up.
/// - A player more than a second and a half away from where it should be is moved; closer is left alone.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../files/files_model.dart';
import '../ui/video_engine.dart';
import 'channels.dart';
import 'voice.dart';

/// What is being watched together.
@immutable
class Watching {
  const Watching({required this.file, required this.space, required this.by, required this.position, required this.playing, required this.at});

  final SpaceFile file;

  /// The Files space it is in, by its seed.
  final String space;

  /// Who started it.
  final String by;

  /// Where it was, and whether it played, when [at] was.
  final Duration position;
  final bool playing;
  final DateTime at;

  /// Where it is now, by the clock.
  Duration now([DateTime? when]) => playing ? position + (when ?? DateTime.now()).difference(at) : position;

  /// The same watch at a new place, stamped with now.
  Watching moved({required Duration position, required bool playing}) => Watching(file: file, space: space, by: by, position: position, playing: playing, at: DateTime.now());

  /// As said in the call ('wt'): the file, its space, the place in milliseconds and whether it plays. Who and when
  /// are not sent; the listener takes them from the sender and its own clock.
  Map<String, Object?> toWire() => {'f': file.toJson(), 's': space, 'p': position.inMilliseconds, 'g': playing};

  static Watching? fromWire(String from, Map<String, dynamic> m, {DateTime? at}) {
    final f = SpaceFile.fromJson(m['f'], by: from);
    if (f == null || m['s'] is! String) return null;
    return Watching(file: f, space: m['s'] as String, by: from, position: Duration(milliseconds: (m['p'] as num?)?.toInt() ?? 0), playing: m['g'] == true, at: at ?? DateTime.now());
  }
}

/// How far a player may be from where it should be before it is moved.
const watchSlack = Duration(milliseconds: 1500);

/// What the call this device is in is watching, and the player's link to it: says what this device's person does to
/// the player, and moves the player to what others say.
class WatchTogether extends ChangeNotifier implements VideoSync {
  WatchTogether._();
  static final WatchTogether instance = WatchTogether._();

  VoiceSession? _session;

  /// What the call is watching; null for nothing.
  Watching? watching;

  VideoEngine? _engine;
  Timer? _beat;

  /// This device is watching it now (its player open).
  bool get here => _engine != null;

  /// Follows the call [Voice] is in.
  void follow() {
    final s = Voice.instance.session;
    if (identical(s, _session)) return;
    _session?.onWatch = null;
    _session = s;
    watching = null;
    _beat?.cancel();
    s?.onWatch = _heard;
    notifyListeners();
  }

  @visibleForTesting
  void followSession(VoiceSession? s) {
    _session?.onWatch = null;
    _session = s;
    watching = null;
    s?.onWatch = _heard;
  }

  /// Starts watching [file] of the Files space [space] with the call, from the start.
  void start(SpaceFile file, VoiceChannel space) {
    final s = _session;
    if (s == null) return;
    watching = Watching(file: file, space: space.seed, by: 'me', position: Duration.zero, playing: true, at: DateTime.now());
    s.sayWatch(watching!.toWire());
    _beat?.cancel();
    _beat = Timer.periodic(const Duration(seconds: 5), (_) => _heartbeat());
    notifyListeners();
  }

  /// Stops it for everyone.
  void stop() {
    _session?.sayWatch({'e': true});
    watching = null;
    _beat?.cancel();
    notifyListeners();
  }

  /// Every five seconds on the device that started it: says where its player is while it plays, and stops itself once
  /// the watch is over or someone else's.
  void _heartbeat() {
    final w = watching, e = _engine, s = _session;
    if (w == null || s == null || w.by != 'me') {
      _beat?.cancel();
      return;
    }
    if (e == null || !w.playing) return;
    watching = w.moved(position: e.value.position, playing: e.value.playing);
    s.sayWatch(watching!.toWire());
  }

  /// Something said about the watch by [from]: `e` ends it; anything else is a file with where it is.
  void _heard(String from, Map<String, dynamic> m) {
    if (m['e'] == true) {
      watching = null;
      notifyListeners();
      return;
    }
    final w = Watching.fromWire(from, m);
    if (w == null) return;
    // Who started it stays who started it; a newer file is a new start.
    final had = watching;
    watching = had != null && had.file.id == w.file.id ? Watching(file: w.file, space: w.space, by: had.by, position: w.position, playing: w.playing, at: w.at) : w;
    _apply();
    notifyListeners();
  }

  /// Moves this device's player to where it should be.
  void _apply() {
    final e = _engine, w = watching;
    if (e == null || w == null || !e.value.ready) return;
    final target = w.now();
    if ((e.value.position - target).abs() > watchSlack) unawaited(e.seek(target));
    if (w.playing && !e.value.playing) unawaited(e.play());
    if (!w.playing && e.value.playing) unawaited(e.pause());
  }

  // --- the player ---------------------------------------------------------------------------------------------------

  @override
  void attach(VideoEngine engine) {
    _engine = engine;
    _apply();
    // A player opened with nothing being watched together just plays.
    if (watching == null) unawaited(engine.play());
    notifyListeners();
  }

  @override
  void user({required bool playing, required Duration position}) {
    final w = watching, s = _session;
    if (w == null || s == null) return;
    watching = w.moved(position: position, playing: playing);
    s.sayWatch(watching!.toWire());
    notifyListeners();
  }

  @override
  void detach(VideoEngine engine) {
    if (identical(_engine, engine)) _engine = null;
    notifyListeners();
  }
}
