/// What the app itself is spending, measured from inside it, for the Performance plugin (lib/plugins/performance.dart;
/// Matt, 2026-11-24: "add a performance plugin that adds a small row to the top of the screen just below the titlebar
/// that shows app usage, spikes and a log we can copy").
///
/// While it runs it reads, every two seconds (every ten with the app put away): how much processor time the whole app
/// used since the last reading, as a share of one core; how much memory it holds; how many frames it drew and how long
/// the slowest took. It writes a line to its log for each **spike**: the processor at half a core or more, a frame of
/// a tenth of a second or more, or the app's own thread held up for three tenths of a second (a reading that came
/// late: nothing else ran in the meantime, which is what a frozen window is). And once a minute it writes what the
/// minute came to, with the busiest threads by name where the system says them (Android and Linux), so that a log
/// copied from a phone says where its battery went.
///
/// Nothing is read until it is started, and nothing leaves the device: the log is words on this device until the
/// person copies them.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../app_seen.dart';
import 'cpu_reading.dart';
import 'cpu_source.dart';

/// One reading.
@immutable
class UsageSample {
  const UsageSample({required this.at, this.cpu, this.memory, this.frames = 0, this.worstFrame = Duration.zero, this.seen = true});
  final DateTime at;

  /// The processor time used since the reading before, as a percentage of one core (200 is two cores flat out); null
  /// where the system can't say.
  final double? cpu;

  /// Memory held, in bytes; null where unknown.
  final int? memory;

  /// Frames drawn since the reading before, and how long the slowest took to build and paint.
  final int frames;
  final Duration worstFrame;

  /// Whether the app could be seen ([AppSeen]).
  final bool seen;
}

class AppUsage extends ChangeNotifier {
  AppUsage({CpuSource? source, DateTime Function()? now})
      : _source = source ?? makeCpuSource(),
        _now = now ?? DateTime.now;

  /// The app's own.
  static AppUsage instance = AppUsage();

  final CpuSource _source;
  final DateTime Function() _now;

  /// How often a reading is taken while the app can be seen, and while it is put away.
  static const every = Duration(seconds: 2);
  static const awayEvery = Duration(seconds: 10);

  /// How often the log is given a line of what the time since the last came to.
  static const summaryEvery = Duration(minutes: 1);

  /// The processor's share of one core at which a reading is a spike.
  static const spikeAt = 50.0;

  /// A frame this long is a spike, and so is the app's thread held up this long past a reading's time.
  static const slowFrame = Duration(milliseconds: 100);
  static const stallAt = Duration(milliseconds: 300);

  /// A reading this late was not the app being busy: the device was asleep.
  static const asleepAt = Duration(seconds: 30);

  /// How many readings are kept for the row's little graph, and how many lines the log holds.
  static const historyMost = 90;
  static const logMost = 500;

  /// The readings, oldest first.
  final List<UsageSample> history = [];
  UsageSample? get last => history.isEmpty ? null : history.last;

  /// The log's lines, oldest first, each beginning with its time.
  final List<String> log = [];

  /// How many spikes since it was started.
  int spikes = 0;

  /// What a copied log begins with: the app, its version and the device, said by whoever starts it.
  String about = 'Uplink';

  Timer? _timer;
  bool get running => _timer != null;
  DateTime? _started;

  // Since the last reading.
  Duration? _used;
  DateTime? _readAt;
  int _frames = 0;
  Duration _worst = Duration.zero;
  DateTime? _slowSaid;

  // A stretch of the processor at [spikeAt] or more: when it began, and its readings.
  DateTime? _busySince;
  final List<double> _busy = [];

  // Since the last line of what the time came to.
  DateTime? _summaryAt;
  Duration? _summaryUsed;
  Map<String, Duration>? _summaryThreads;
  double _summaryMax = 0;
  int _summaryFrames = 0, _summarySlow = 0;
  bool _summarySeen = false, _summaryAway = false;

  /// Begins reading. Safe to call again.
  void start() {
    if (_timer != null) return;
    final now = _now();
    _started = now;
    _used = _source.used();
    _readAt = now;
    _summaryAt = now;
    _summaryUsed = _used;
    _summaryThreads = _source.threads();
    _summarySeen = AppSeen.now.value;
    _summaryAway = !AppSeen.now.value;
    _say(now, 'Started. ${_used == null ? 'This device does not say how much of the processor the app uses: frames, memory and stalls only.' : 'Reading every ${every.inSeconds} s, every ${awayEvery.inSeconds} s while put away.'}');
    try {
      SchedulerBinding.instance.addTimingsCallback(_drawn);
    } catch (_) {
      // No app to draw frames (a plain test).
    }
    AppSeen.follow();
    AppSeen.now.addListener(_seenChanged);
    _arm();
  }

  /// Stops reading. The log and the readings stay until it is started again.
  void stop() {
    if (_timer == null) return;
    _timer?.cancel();
    _timer = null;
    AppSeen.now.removeListener(_seenChanged);
    try {
      SchedulerBinding.instance.removeTimingsCallback(_drawn);
    } catch (_) {}
    _say(_now(), 'Stopped.');
    notifyListeners();
  }

  /// Forgets the log, the readings and the count of spikes.
  void clear() {
    log.clear();
    history.clear();
    spikes = 0;
    _busySince = null;
    _busy.clear();
    notifyListeners();
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer.periodic(AppSeen.now.value ? every : awayEvery, (_) => sample());
  }

  void _seenChanged() {
    if (_timer == null) return;
    final seen = AppSeen.now.value;
    _say(_now(), seen ? 'Brought back.' : 'Put away.');
    if (seen) {
      _summarySeen = true;
    } else {
      _summaryAway = true;
    }
    // A reading now, so that what was spent out of sight is not counted with what is spent in sight; and no stall is
    // read into the gap, since a phone holds a put-away app's timers back itself.
    sample(gap: true);
    _arm();
  }

  void _drawn(List<FrameTiming> timings) {
    for (final t in timings) {
      _frames++;
      _summaryFrames++;
      final took = t.buildDuration + t.rasterDuration;
      if (took > _worst) _worst = took;
      if (took >= const Duration(milliseconds: 34)) _summarySlow++;
      if (took >= slowFrame) {
        // At most one line a second: a run of slow frames is one stumble.
        final now = _now();
        if (_slowSaid == null || now.difference(_slowSaid!) >= const Duration(seconds: 1)) {
          _slowSaid = now;
          _spike(now, 'A frame took ${took.inMilliseconds} ms (building ${t.buildDuration.inMilliseconds}, painting ${t.rasterDuration.inMilliseconds}).');
        }
      }
    }
  }

  /// One reading, now. [gap]: the time since the last was not this one's own period (the app was just put away or
  /// brought back), so being late says nothing.
  void sample({bool gap = false}) {
    final now = _now();
    final was = _readAt;
    final seen = AppSeen.now.value;
    final period = seen ? every : awayEvery;
    final passed = was == null ? period : now.difference(was);
    // Held up: the reading came this much later than its time, and while the app is in sight nothing but the app's own
    // thread being busy makes it late.
    // So late that it was not the app at all: the computer slept, or the system set the app aside.
    final late = passed - period;
    final asleep = !gap && seen && late >= asleepAt;
    if (asleep) {
      _say(now, 'Nothing was read for ${_span(passed)}: the device slept, or the app was set aside.');
    } else if (!gap && seen && late >= stallAt) {
      _spike(now, 'The app was held up for ${late.inMilliseconds} ms: nothing else on its thread ran in that time.');
    }
    final used = _source.used();
    double? cpu;
    // Over a sleep there is no share to speak of: the time was not the app's to spend.
    if (!asleep && used != null && _used != null && passed > Duration.zero) cpu = 100 * (used - _used!).inMicroseconds / passed.inMicroseconds;
    _used = used;
    _readAt = now;
    final reading = UsageSample(at: now, cpu: cpu, memory: _source.memory(), frames: _frames, worstFrame: _worst, seen: seen);
    _frames = 0;
    _worst = Duration.zero;
    history.add(reading);
    if (history.length > historyMost) history.removeRange(0, history.length - historyMost);
    if (cpu != null) {
      if (cpu > _summaryMax) _summaryMax = cpu;
      _busyReading(now, cpu, passed);
    }
    if (asleep) {
      // The minute's line would average the sleep in: it begins again from here.
      _summaryAt = now;
      _summaryUsed = used;
      _summaryThreads = _source.threads();
      _summaryMax = 0;
      _summaryFrames = 0;
      _summarySlow = 0;
    } else if (_summaryAt != null && now.difference(_summaryAt!) >= summaryEvery) {
      _summary(now);
    }
    notifyListeners();
  }

  /// A stretch at [spikeAt] or more is one spike: said as it begins, and again as it ends with how long it lasted.
  void _busyReading(DateTime now, double cpu, Duration passed) {
    if (cpu >= spikeAt) {
      if (_busySince == null) {
        _busySince = now.subtract(passed);
        _busy.clear();
        _spike(now, 'The processor at ${cpu.round()}% of a core.');
      }
      _busy.add(cpu);
    } else if (_busySince != null) {
      final lasted = now.subtract(passed).difference(_busySince!);
      final mean = _busy.reduce((a, b) => a + b) / _busy.length;
      _say(now, 'Back to ${cpu.round()}%, after ${_span(lasted)} at ${mean.round()}% on average.');
      _busySince = null;
      _busy.clear();
    }
  }

  /// What the time since the last such line came to, with the busiest threads where the system names them.
  void _summary(DateTime now) {
    final since = _summaryAt!;
    final wall = now.difference(since);
    final used = _used, before = _summaryUsed;
    final parts = <String>[];
    if (used != null && before != null && wall > Duration.zero) {
      parts.add('processor ${_pct(100 * (used - before).inMicroseconds / wall.inMicroseconds)} of a core on average, ${_pct(_summaryMax)} at most');
    }
    final memory = _source.memory();
    if (memory != null) parts.add('memory ${(memory / 1048576).round()} MB');
    if (_summaryFrames > 0) parts.add('$_summaryFrames frames${_summarySlow > 0 ? ' ($_summarySlow slow)' : ''}');
    final threads = _source.threads(), threadsBefore = _summaryThreads;
    if (threads != null && threadsBefore != null && wall > Duration.zero) {
      final spent = [
        for (final e in threads.entries)
          if (e.value - (threadsBefore[e.key] ?? Duration.zero) > Duration.zero) (name: e.key, share: 100 * (e.value - (threadsBefore[e.key] ?? Duration.zero)).inMicroseconds / wall.inMicroseconds),
      ]..sort((a, b) => b.share.compareTo(a.share));
      // The busiest six, and none that did next to nothing (under a twentieth of a percent).
      final busy = [for (final t in spent.take(6)) if (t.share >= 0.05) t];
      if (busy.isNotEmpty) parts.add('threads: ${busy.map((t) => '${t.name} ${_pct(t.share)}').join(', ')}');
    }
    final where = _summaryAway && !_summarySeen ? 'Put away, ' : (_summaryAway ? 'Partly put away, ' : '');
    if (parts.isNotEmpty) _say(now, '$where${_span(wall)}: ${parts.join('; ')}.');
    _summaryAt = now;
    _summaryUsed = used;
    _summaryThreads = threads;
    _summaryMax = 0;
    _summaryFrames = 0;
    _summarySlow = 0;
    _summarySeen = AppSeen.now.value;
    _summaryAway = !AppSeen.now.value;
  }

  void _spike(DateTime at, String what) {
    spikes++;
    _say(at, 'Spike: $what');
    if (_timer != null) notifyListeners();
  }

  void _say(DateTime at, String what) {
    log.add('${_clock(at)}  $what');
    if (log.length > logMost) log.removeRange(0, log.length - logMost);
  }

  /// The log as words to copy: what it is of, when it began, how many spikes, then every line.
  String text() {
    final started = _started;
    return [
      '$about: performance log',
      if (started != null) 'Began ${started.year}-${_two(started.month)}-${_two(started.day)} ${_clock(started)}; $spikes ${spikes == 1 ? 'spike' : 'spikes'}.',
      '',
      ...log,
    ].join('\n');
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _clock(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

  /// "3%", "0.4%" under one, "112%".
  static String _pct(double p) => p < 1 ? '${p.toStringAsFixed(1)}%' : '${p.round()}%';

  /// "58 s", "2 min 5 s".
  static String _span(Duration d) => d.inSeconds < 60 ? '${d.inSeconds} s' : '${d.inMinutes} min ${d.inSeconds % 60} s';

  /// A reading in a few words, for the row: "3%", or "–" where unknown.
  static String cpuWords(double? cpu) => cpu == null ? '–' : _pct(cpu);
}
