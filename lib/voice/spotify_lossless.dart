/// A circle's music without loss (Matt, 2026-11-25: "the audio doesn't sound high quality for the other user they said it
/// sounds compressed I'd like it to stream lossless audio", then "lossless now and 510"): what Spotify plays on the DJ's
/// computer, 48 kHz stereo 16-bit as it was captured, packed without loss (FLAC) and sent on a data channel beside the
/// Opus, on the same connection. The Opus goes on all the while and is what is heard until this has played cleanly for a
/// second, and at once when it stops.
///
/// Here, with nothing of the screen or of WebRTC in it: what a chunk is ([MusicChunk]), the listener's side ([LosslessEar]:
/// what waits, clock drift, when it may be heard), and the DJ's ([LosslessWay]: what is dropped for one listener;
/// [LosslessDesk]: who has it at all).
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'flac.dart';
import 'music_sink.dart';

/// The label of the channel it goes on.
const losslessLabel = 'music';

/// Frames a second.
const losslessRate = 48000;

/// Some frames of it, as they come: version, flags, count, running number, length, payload (native/voicefx
/// music_pack.h). Read within bounds, and unpacked only where it says nothing that can't be.
class MusicChunk {
  const MusicChunk._(this.at, this.frames, this.flac, this.payload);

  static const head = 12, now = 1, _flac = 1;

  /// The longest there may be.
  static const most = head + Flac.most * 4 + 64;

  /// The number of its first frame since the DJ's sound began, and how many there are.
  final int at, frames;
  final bool flac;
  final Uint8List payload;

  /// What version made [bytes]: one that isn't known is not guessed at, and the channel is done with.
  static int? version(Uint8List bytes) => bytes.isEmpty ? null : bytes[0];

  static MusicChunk? read(Uint8List bytes) {
    if (bytes.length <= head || bytes.length > most || bytes[0] != now) return null;
    final d = ByteData.sublistView(bytes);
    final flags = d.getUint8(1), frames = d.getUint16(2, Endian.little);
    if (flags & ~_flac != 0 || frames < 16 || frames > Flac.most) return null;
    final flac = flags & _flac != 0, length = d.getUint16(10, Endian.little);
    if (length != bytes.length - head || (!flac && length != frames * 4)) return null;
    return MusicChunk._(d.getUint32(4, Endian.little) + d.getUint16(8, Endian.little) * 0x100000000, frames, flac, Uint8List.sublistView(bytes, head));
  }

  /// Its samples, interleaved; null where they are broken.
  Int16List? samples() {
    if (flac) return Flac.read(payload, frames);
    final d = ByteData.sublistView(payload);
    return Int16List.fromList([for (var i = 0; i < frames * 2; i++) d.getInt16(i * 2, Endian.little)]);
  }
}

/// Takes one frame out of [lr], or puts one in, where it is heard least: at the smallest step between neighbours. The
/// DJ's clock and this device's are never quite the same, and this is all that is ever done about it.
abstract final class Drift {
  static int _step(Int16List x, int a, int b) => (x[a * 2] - x[b * 2]).abs() + (x[a * 2 + 1] - x[b * 2 + 1]).abs();

  static Int16List fewer(Int16List x) {
    final n = x.length ~/ 2;
    if (n < 4) return x;
    var best = 1, least = 1 << 30;
    for (var i = 1; i < n - 1; i++) {
      final s = _step(x, i - 1, i + 1);
      if (s < least) {
        least = s;
        best = i;
      }
    }
    return Int16List((n - 1) * 2)
      ..setRange(0, best * 2, x)
      ..setRange(best * 2, (n - 1) * 2, x, (best + 1) * 2);
  }

  static Int16List more(Int16List x) {
    final n = x.length ~/ 2;
    if (n < 4) return x;
    var best = 0, least = 1 << 30;
    for (var i = 0; i < n - 1; i++) {
      final s = _step(x, i, i + 1);
      if (s < least) {
        least = s;
        best = i;
      }
    }
    final out = Int16List((n + 1) * 2)..setRange(0, (best + 1) * 2, x);
    out[(best + 1) * 2] = (x[best * 2] + x[best * 2 + 2]) ~/ 2;
    out[(best + 1) * 2 + 1] = (x[best * 2 + 1] + x[best * 2 + 3]) ~/ 2;
    return out..setRange((best + 2) * 2, (n + 1) * 2, x, (best + 1) * 2);
  }
}

/// The listener's side: chunks in ([take]), the player fed, and said when it may be heard in the Opus's place ([onHeard])
/// and when it isn't to be tried any more for now ([onGiveUp]).
class LosslessEar {
  LosslessEar({required this.sink, required this.onHeard, required this.onGiveUp, DateTime Function()? clock}) : clock = clock ?? DateTime.now;
  final MusicSink sink;

  /// The music is heard from here now (the Opus is to be silent), or it isn't (the Opus is to be heard, at once).
  final void Function(bool on) onHeard;

  /// Nothing more is taken: the connection can't keep up, or what comes is nothing this build knows.
  final void Function(LosslessWhy why) onGiveUp;
  final DateTime Function() clock;

  /// What waits before any of it is played: 600 ms. Past [most] of it waiting, what comes is let go of.
  static const start = losslessRate * 6 ~/ 10, most = losslessRate * 2;

  /// How long it plays, unheard, before it is heard in the Opus's place.
  static const proving = losslessRate;

  /// A gap no longer than this is played as silence, so what comes after keeps its time; past it everything starts again.
  static const gapMost = losslessRate;

  /// How far what waits may be from [start], and how near it is brought back to, before the clocks are evened out.
  static const driftMost = losslessRate ~/ 12, driftNear = losslessRate ~/ 50;

  /// Left waiting when nothing has come: the Opus is heard from here, before the player runs out.
  static const low = losslessRate * 12 ~/ 100;

  /// This many times in trouble within [strikeWindow], and it isn't tried any more for now.
  static const strikes = 3, strikeWindow = Duration(seconds: 60);

  bool _opened = false, _opening = false, _closed = false, _priming = true, _heard = false;
  int? _next;
  final List<Int16List> _held = [];
  int _heldFrames = 0;

  /// What the player had waiting when it last said, what has been given to it since, and how often it had run out (-1:
  /// not known since it last began).
  int _waiting = 0, _flying = 0, _dry = -1;

  /// What was written to it since it last began, for the second it has to prove.
  int _given = 0;
  double? _fill;
  int _evening = 0;
  Timer? _lowTimer;
  final List<DateTime> _troubles = [];

  /// Whether the DJ plays: while they don't, nothing coming is no trouble.
  bool get playing => _playing;
  bool _playing = true, _paused = false;
  set playing(bool on) {
    _playing = on;
    if (!on) _paused = true;
  }

  bool get heard => _heard;

  /// For whoever wants to know: the frames written, the chunks that were broken, gaps, repeats, and frames put in or out.
  int written = 0, broken = 0, gaps = 0, repeats = 0, evened = 0;

  final List<({int to, double peak})> _peaks = [];

  /// How loud what plays now is, 0 to 1.
  double level() {
    final at = written - (_waiting + _flying);
    while (_peaks.length > 1 && _peaks.first.to < at) {
      _peaks.removeAt(0);
    }
    return _priming || _peaks.isEmpty ? 0 : _peaks.first.peak;
  }

  /// A message of the channel's.
  void take(Uint8List bytes) {
    if (_closed) return;
    final c = MusicChunk.read(bytes);
    if (c == null) {
      final v = MusicChunk.version(bytes);
      if (v != null && v != MusicChunk.now) return _giveUp(LosslessWhy.version);
      return _bad();
    }
    if (_playing) _paused = false;
    final next = _next;
    if (next != null && c.at < next) {
      // Come before, or come late: what is played is never gone back on.
      repeats++;
      return;
    }
    // More than the player may hold: someone sends faster than it plays, or it does not play.
    if (_waiting + _flying + _heldFrames + c.frames > most) {
      _reset();
      _trouble();
      return;
    }
    final lr = c.samples();
    if (lr == null) return _bad();
    if (next != null && c.at > next) {
      gaps++;
      final gap = c.at - next;
      _trouble();
      if (_closed) return;
      if (gap > gapMost) {
        _reset();
      } else if (!_priming) {
        _give(Int16List(gap * 2));
      }
    }
    _next = c.at + c.frames;
    if (_priming) {
      _held.add(lr);
      _heldFrames += c.frames;
      unawaited(_begin());
      return;
    }
    _give(_even(lr));
  }

  void _bad() {
    broken++;
    _trouble();
  }

  Future<void> _begin() async {
    if (_heldFrames < start || _opening) return;
    if (!_opened) {
      _opening = true;
      final ok = await sink.open(device).catchError((_) => false);
      _opening = false;
      if (_closed) {
        if (ok) unawaited(sink.close().catchError((_) {}));
        return;
      }
      if (!ok) return _giveUp(LosslessWhy.sink);
      _opened = true;
      await sink.set(volume: _volume, silent: true).catchError((_) {});
      if (_closed || _heldFrames < start) return;
    }
    _priming = false;
    _given = 0;
    _fill = null;
    _dry = -1;
    _paused = !_playing;
    final held = _held.toList();
    _held.clear();
    _heldFrames = 0;
    for (final lr in held) {
      _give(lr);
    }
  }

  Int16List _even(Int16List lr) {
    final fill = _fill;
    if (fill == null) return lr;
    final off = fill - start;
    if (_evening == 0 && off.abs() > driftMost) _evening = off > 0 ? 1 : -1;
    if (_evening != 0 && off * _evening < driftNear) _evening = 0;
    if (_evening == 0) return lr;
    evened++;
    return _evening > 0 ? Drift.fewer(lr) : Drift.more(lr);
  }

  void _give(Int16List lr) {
    final n = lr.length ~/ 2;
    written += n;
    _given += n;
    _flying += n;
    var peak = 0;
    for (final v in lr) {
      peak = math.max(peak, v.abs());
    }
    _peaks.add((to: written, peak: peak / 32768));
    if (_peaks.length > 200) _peaks.removeAt(0);
    final bytes = ByteData(lr.length * 2);
    for (var i = 0; i < lr.length; i++) {
      bytes.setInt16(i * 2, lr[i], Endian.little);
    }
    unawaited(sink.write(bytes.buffer.asUint8List()).then((now) => _said(n, now)).catchError((_) => _said(n, null)));
  }

  void _said(int frames, SinkNow? now) {
    _flying = math.max(0, _flying - frames);
    if (_closed) return;
    if (now == null) return _giveUp(LosslessWhy.sink);
    // What ran out while it waited to begin is no trouble.
    final ran = _dry >= 0 && now.dry > _dry;
    if (_priming) return;
    _dry = now.dry;
    _waiting = now.waiting;
    if (ran) {
      // It ran out though it was not foreseen ([_runLow]): begun again.
      _restart();
      _trouble(quiet: _paused);
      return;
    }
    // Smoothed over some seconds, as what comes does not come evenly; with what was given and not answered for yet.
    final f = _fill, fill = (_waiting + _flying).toDouble();
    _fill = f == null ? fill : f + (fill - f) * 0.02;
    _watchLow();
    if (!_heard && _given - _waiting - _flying >= proving) _hear(true);
  }

  /// Told when no more has come and little is left: [low] frames before the player runs out.
  void _watchLow() {
    _lowTimer?.cancel();
    final ms = (_waiting + _flying - low) * 1000 ~/ losslessRate;
    _lowTimer = Timer(Duration(milliseconds: math.max(0, ms)), _runLow);
  }

  void _runLow() {
    if (_closed || _priming) return;
    _restart();
    // Nothing coming is trouble only where something should be: paused, the Opus has nothing in it either.
    _trouble(quiet: _paused || !_playing);
  }

  /// Waits for [start] again, with what the player has left played out.
  void _restart() {
    _lowTimer?.cancel();
    _priming = true;
    _given = 0;
    _fill = null;
    _evening = 0;
    _held.clear();
    _heldFrames = 0;
  }

  /// Everything from the beginning: nothing that came is kept.
  void _reset() {
    _restart();
    _next = null;
    _waiting = 0;
    unawaited(sink.clear().catchError((_) {}));
  }

  /// Not clean: the Opus is heard at once, and the second to prove begins again. [quiet]: it counts for nothing more.
  void _trouble({bool quiet = false}) {
    _hear(false);
    _given = 0;
    if (quiet) return;
    final now = clock();
    _troubles.removeWhere((t) => now.difference(t) >= strikeWindow);
    _troubles.add(now);
    if (_troubles.length >= strikes) _giveUp(LosslessWhy.slow);
  }

  void _hear(bool on) {
    if (_heard == on) return;
    _heard = on;
    onHeard(on);
    _tune();
  }

  // --- how loud, and where ---------------------------------------------------------------------------------------------

  double _volume = 1;
  bool _silent = false;
  String device = '';

  void set({required double volume, required bool silent}) {
    if (volume == _volume && silent == _silent) return;
    _volume = volume;
    _silent = silent;
    _tune();
  }

  void _tune() {
    if (_opened && !_closed) unawaited(sink.set(volume: _volume, silent: _silent || !_heard).catchError((_) {}));
  }

  void output(String to) {
    if (to == device) return;
    device = to;
    if (_opened && !_closed) unawaited(sink.output(to).catchError((_) {}));
  }

  void _giveUp(LosslessWhy why) {
    if (_closed) return;
    close();
    onGiveUp(why);
  }

  /// Ends it: the Opus is heard, and the player is let go of.
  void close() {
    if (_closed) return;
    _hear(false);
    _closed = true;
    _lowTimer?.cancel();
    _held.clear();
    _heldFrames = 0;
    if (_opened) unawaited(sink.close().catchError((_) {}));
  }
}

/// Why a listener has the Opus and not the music without loss; [word] is what is said of it between devices.
enum LosslessWhy {
  /// Switched off on this device.
  off(''),

  /// The DJ's build is from before it.
  old(''),

  /// This device has no player for it.
  device(''),

  /// The sound comes out of a speaker, and the microphone would send it back ([MusicTo.speakers]).
  speakers(''),

  /// The system doesn't say whether it is worn, and neither has this device's person ([MusicTo.unknown]).
  unknown(''),

  /// A Bluetooth headset in a call.
  callHeadset(''),

  /// The connection goes through the relay, which is never sent it.
  relay('relay'),

  /// The connection, or the DJ's, can't keep up: tried again later.
  slow('slow'),

  /// As many as the DJ's connection can send it to have it already.
  full('full'),

  /// The player could not be opened, or stopped.
  sink(''),

  /// The DJ's build sends it in a way this one doesn't know.
  version('');

  const LosslessWhy(this.word);
  final String word;

  static LosslessWhy? said(Object? word) => word is! String || word.isEmpty ? null : values.where((w) => w.word == word).firstOrNull;

  /// In plain words, for this device's person.
  String get words => switch (this) {
        off => 'Lossless music is off on this device.',
        old => 'The DJ\'s version of Uplink doesn\'t send it.',
        device => 'This device can\'t play it without loss: it hears the high quality stream.',
        speakers => 'On speakers your microphone would send the music back to the call. Wear headphones for lossless.',
        unknown => 'This device can\'t tell whether you wear headphones. On speakers your microphone would send the music back to the call.',
        callHeadset => 'Your Bluetooth headset is in a call, and plays everything at a call\'s quality until its microphone is let go of. Choose another microphone, or wired headphones.',
        relay => 'Your connection to the DJ goes through the relay, which isn\'t sent lossless music.',
        slow => 'The connection to the DJ can\'t keep up with lossless right now. It is tried again by itself.',
        full => 'As many people as the DJ\'s connection can send lossless to have it already.',
        sink => 'The player on this device couldn\'t be opened.',
        version => 'The DJ\'s version sends lossless in a way this one doesn\'t know. Update Uplink.',
      };
}

/// One listener's chunks on their way out of the DJ's device, where Dart sends them (a PC; a Mac's are sent natively,
/// LosslessWay in macos/Runner/MusicLink.swift, and by the same rule): what can't be sent in time is dropped, whole
/// chunks and the oldest first, rather than queued.
class LosslessWay {
  LosslessWay({required this.send, required this.buffered});

  /// Gives WebRTC a chunk; and what it has not sent, in bytes.
  final Future<void> Function(Uint8List chunk) send;
  final Future<int> Function() buffered;

  static const mostChunks = 5, mostWaiting = 48 * 1024;

  /// The channel is open; and it is known that the connection goes through no relay.
  bool isOpen = false, allowed = false;
  int sent = 0, bytes = 0, dropped = 0;
  final List<Uint8List> _held = [];
  int _waiting = 0;
  bool _asking = false;

  void push(Uint8List chunk) {
    if (!isOpen || !allowed) {
      _held.clear();
      return;
    }
    _held.add(chunk);
    _drain();
    while (_held.length > mostChunks) {
      _held.removeAt(0);
      dropped++;
    }
    unawaited(_ask());
  }

  void _drain() {
    while (_held.isNotEmpty && _waiting + _held.first.length <= mostWaiting) {
      final c = _held.removeAt(0);
      _waiting += c.length;
      sent++;
      bytes += c.length;
      unawaited(send(c).catchError((_) {}));
    }
  }

  Future<void> _ask() async {
    if (_asking) return;
    _asking = true;
    try {
      _waiting = await buffered();
      if (isOpen && allowed) _drain();
    } catch (_) {
    } finally {
      _asking = false;
    }
  }
}

/// How it goes for one listener, as the DJ's device has it: [relay] null until it is known.
typedef LosslessState = ({bool open, int bytes, int dropped, bool? relay});

/// What the DJ's device is to do for [id]: begin ([LosslessBegin]), end, with why ([LosslessEnd]), or only tell them how it
/// stands ([LosslessTell]).
sealed class LosslessDo {
  const LosslessDo(this.id);
  final String id;
}

class LosslessBegin extends LosslessDo {
  const LosslessBegin(super.id);
}

class LosslessEnd extends LosslessDo {
  const LosslessEnd(super.id, this.why);
  final LosslessWhy why;
}

class LosslessTell extends LosslessDo {
  const LosslessTell(super.id, this.why);
  final LosslessWhy? why;
}

/// Who has the music without loss, at the DJ's: those who asked, as many as the connection out of here takes, never
/// through a relay (each way is shut natively until it is known to go through none), and again after a while for whoever
/// could not keep up.
class LosslessDesk {
  LosslessDesk({required this.clock});
  final DateTime Function() clock;

  /// How many it begins with, and never more.
  static const begins = 6;

  /// This many chunks dropped within [dropWindow], and the listener has the Opus for a while: [rests], and longer each time.
  static const dropsMost = 10, dropWindow = Duration(seconds: 10);
  static const rests = [Duration(minutes: 1), Duration(minutes: 2), Duration(minutes: 4), Duration(minutes: 8)];

  /// Kept up with for this long and the next rest is a short one again.
  static const wellAfter = Duration(minutes: 10);

  /// With no such trouble for this long, one more may have it than the last left.
  static const growsEvery = Duration(minutes: 5);

  /// A connection often begins through the relay and goes on directly a moment later: said only past this.
  static const relayedFor = Duration(seconds: 10);

  final Map<String, _Desked> _all = {};
  bool get isEmpty => _all.isEmpty;

  /// How many may have it now: fewer once several at a time could not be kept up with, which is this device's own
  /// connection and not theirs.
  int cap = begins;
  DateTime? _capAt, _lookedAt;

  /// How many have it, and what it takes, in bits a second, over the last look.
  int get having => _all.values.where((d) => d.has && d.open && d.relaySince == null).length;
  double bitsPerSecond = 0;

  /// [id] asked for the music: [wants] it without loss, or only might ([LosslessEnd] follows).
  void asked(String id, {required bool wants}) => (_all[id] ??= _Desked()).wants = wants;

  /// [id]'s connection has been made, with a channel or without one.
  void offered(String id, {required bool channel}) {
    final d = _all[id] ??= _Desked();
    d
      ..room = channel
      ..has = channel
      ..open = false
      ..full = false
      ..bytes = 0
      ..dropped = 0
      ..since = clock()
      ..relaySince = null
      ..relaySaid = false;
    d.drops.clear();
  }

  /// [id] said it is not to be sent it, or is again; [slow] where it could not keep up.
  void said(String id, {required bool wants, bool slow = false}) {
    final d = _all[id];
    if (d == null) return;
    d.wants = wants || slow;
    if (slow && d.has) _rest(d);
  }

  void gone(String id) => _all.remove(id);

  void clear() {
    _all.clear();
    cap = begins;
    _capAt = _lookedAt = null;
    bitsPerSecond = 0;
  }

  void _rest(_Desked d) {
    final now = clock();
    if (d.since != null && now.difference(d.since!) > wellAfter) d.rested = 0;
    d.until = now.add(rests[math.min(d.rested, rests.length - 1)]);
    d.rested++;
  }

  /// Looks at how it goes, [now] for each who is sent it, and says what is to be done. Once a second.
  List<LosslessDo> look(Map<String, LosslessState> now) {
    final at = clock();
    final out = <LosslessDo>[];
    final passed = _lookedAt == null ? 0.0 : at.difference(_lookedAt!).inMilliseconds / 1000;
    _lookedAt = at;
    var bytes = 0;
    final struggling = <String>[];
    bool resting(_Desked d) => d.until != null && at.isBefore(d.until!);

    for (final MapEntry(key: id, value: d) in _all.entries) {
      final s = now[id];
      d.open = s?.open ?? false;
      if (s == null) continue;
      bytes += math.max(0, s.bytes - d.bytes);
      d.bytes = s.bytes;
      if (s.dropped > d.dropped) d.drops.add((at: at, n: s.dropped - d.dropped));
      d.dropped = s.dropped;
      d.drops.removeWhere((x) => at.difference(x.at) >= dropWindow);
      if (d.has && d.drops.fold(0, (sum, x) => sum + x.n) >= dropsMost) struggling.add(id);
      if (s.relay == true) {
        d.relaySince ??= at;
      } else if (s.relay == false) {
        d.relaySince = null;
      }
    }
    if (passed > 0) bitsPerSecond = bytes * 8 / passed;

    // Several at once: what goes out of here is too much, and the one who began last is let go of (below). One: theirs is.
    if (struggling.length > 1) {
      cap = math.max(1, math.min(cap, _all.values.where((d) => d.has).length) - 1);
      _capAt = at;
      for (final id in struggling) {
        _all[id]!.drops.clear();
      }
    } else if (struggling.length == 1) {
      _rest(_all[struggling.single]!);
    } else if (cap < begins && at.difference(_capAt!) >= growsEvery) {
      cap++;
      _capAt = at;
    }

    for (final MapEntry(key: id, value: d) in _all.entries) {
      if (!d.has) continue;
      if (!d.wants || resting(d)) {
        d
          ..has = false
          ..since = at;
        out.add(LosslessEnd(id, d.wants ? LosslessWhy.slow : LosslessWhy.off));
        continue;
      }
      final relayed = d.relaySince != null && at.difference(d.relaySince!) >= relayedFor;
      if (relayed != d.relaySaid) {
        d.relaySaid = relayed;
        out.add(LosslessTell(id, relayed ? LosslessWhy.relay : null));
      }
    }
    // Past the cap: the newest go. One whose connection goes through the relay is sent nothing, and takes no place.
    final has = _all.entries.where((e) => e.value.has && e.value.relaySince == null).toList()..sort((a, b) => a.value.since!.compareTo(b.value.since!));
    while (has.length > cap) {
      final last = has.removeLast();
      last.value
        ..has = false
        ..full = true
        ..since = at;
      out.add(LosslessEnd(last.key, LosslessWhy.full));
    }
    // And room: whoever may have it and doesn't, the one waiting longest first.
    final waiting = _all.entries.where((e) => !e.value.has && e.value.room && e.value.wants && !resting(e.value)).toList()..sort((a, b) => a.value.since!.compareTo(b.value.since!));
    for (final e in waiting) {
      final d = e.value;
      if (has.length >= cap) {
        if (!d.full) out.add(LosslessTell(e.key, LosslessWhy.full));
        d.full = true;
        continue;
      }
      d
        ..has = true
        ..full = false
        ..since = at
        ..bytes = 0
        ..dropped = 0;
      d.drops.clear();
      has.add(e);
      out.add(LosslessBegin(e.key));
    }
    return out;
  }
}

class _Desked {
  bool wants = false, room = false, has = false, open = false, full = false, relaySaid = false;
  int bytes = 0, dropped = 0, rested = 0;
  final List<({DateTime at, int n})> drops = [];

  /// When it began, or was last ended: since when it has had it, or waited for it.
  DateTime? since, until, relaySince;
}
