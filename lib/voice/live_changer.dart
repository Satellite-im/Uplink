import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'channels.dart';
import 'voice_changer.dart';
import 'voice_fx.dart';

/// The voice changer live in a space's call (Matt, 2026-11-20: "I'd like the voice changer to work in spaces calles in
/// real time").
///
/// **On this device, by default** (Matt, 2026-11-21: "Add support (by default) for the voice changer to use on the fly
/// voice changing the elevenlabs is very slow and not real time"): a [VoiceEffect] made by the microphone engine as
/// the voice goes into the call (native/voicefx voicefx_effect), about a fiftieth of a second behind, free, and
/// nothing leaves the device.
///
/// **By ElevenLabs**, where chosen: ElevenLabs changes a voice from a whole recording, not as it streams, so a call's voice goes a phrase at a time:
/// the microphone engine (native/voicefx, voicefx_live) keeps what is said instead of sending it; [PhraseCutter] cuts
/// it at the pauses (or at [PhraseCutter.longest]); each phrase goes to ElevenLabs (VoiceChanger.convertPhrase) and
/// what comes back is fed into the call in its place. Others hear each phrase a moment after it is said; between
/// phrases they hear silence, never the voice itself.
///
/// Nothing is sent while muted, and what was said while muted is let go. Where ElevenLabs refuses, the call stays
/// silent from this device (the voice is never let through unchanged) and the line over the call says why, with a way
/// back to one's own voice.
class LiveChanger extends ChangeNotifier {
  LiveChanger({this.take = VoiceFx.take, this.feed = VoiceFx.feed, this.setLive = VoiceFx.live, this.setEffect = VoiceFx.effect, Future<Uint8List> Function(Uint8List wav)? convert, bool Function()? shouldRun, bool Function()? muted, CallVoiceWay Function()? way, VoiceEffect Function()? effect})
      : _convert = convert ?? VoiceChanger.instance.convertPhrase,
        _shouldRun = shouldRun ?? _wanted,
        _way = way ?? (() => VoiceChanger.instance.way),
        _effectNow = effect ?? (() => VoiceChanger.instance.effect),
        _muted = muted ?? (() => Voice.instance.session?.muted ?? true);

  /// The one for the app: it follows the settings too, so turning live off (or the plugin, or a pause) in a call
  /// gives the voice back at once.
  static final LiveChanger instance = LiveChanger().._watchSettings();

  void _watchSettings() => VoiceChanger.instance.addListener(() => unawaited(follow()));

  /// The microphone engine's three for ElevenLabs' way (VoiceFx.take, feed, live): what was said since last asked, the
  /// changed voice put into the call, and the switch that keeps the voice itself out of it. A test gives its own.
  final Future<Uint8List> Function({int most}) take;
  final Future<int> Function(Uint8List pcm, int rate) feed;
  final Future<bool> Function(bool on) setLive;

  /// The effect made on this device ('none' for none): VoiceFx.effect.
  final Future<bool> Function(String name) setEffect;

  // The settings and the call, as [follow] and the phrase loop ask them: the way and the effect chosen, ElevenLabs'
  // changing of one phrase, whether to run at all, and whether this device is muted.
  final CallVoiceWay Function() _way;
  final VoiceEffect Function() _effectNow;
  final Future<Uint8List> Function(Uint8List wav) _convert;
  final bool Function() _shouldRun;
  final bool Function() _muted;

  /// Whether to run now: in a call, live changing on and ready, and this device's microphone engine able to do the
  /// way chosen.
  static bool _wanted() {
    if (Voice.instance.session == null || !VoiceChanger.instance.liveActive) return false;
    return VoiceChanger.instance.way == CallVoiceWay.device ? VoiceFx.effectsSupported : VoiceFx.liveSupported;
  }

  // ElevenLabs' way: the cutter, the phrases cut and not yet sent (three at most), and the timer that reads.
  final PhraseCutter _cutter = PhraseCutter();
  final List<Uint8List> _waiting = [];
  Timer? _tick;
  bool _on = false, _sending = false;

  /// Running in the call now.
  bool get on => _on;

  /// How it is running: an effect made here, or ElevenLabs; and which effect. Null while off.
  CallVoiceWay? get running => _on ? _running : null;
  CallVoiceWay _running = CallVoiceWay.device;
  VoiceEffect? get effect => _on && _running == CallVoiceWay.device ? _effect : null;
  VoiceEffect? _effect;

  /// A phrase is with ElevenLabs.
  bool get changing => _sending;

  /// Why the last phrase could not be changed; null while all is well.
  String? get problem => _problem;
  String? _problem;

  /// How far behind the voice is heard, roughly: the last phrase's length and its round trip.
  Duration get behind => _behind;
  Duration _behind = Duration.zero;

  /// Follows the call there is and the settings (called as a call is joined and left, and as the settings change).
  ///
  /// An effect made here (the default) is the native half's alone: switched on, and nothing else to do. ElevenLabs
  /// is the phrase loop below.
  Future<void> follow() async {
    final want = _shouldRun();
    final way = _way();
    final effect = _effectNow();
    if (want == _on && (!want || (way == _running && (way != CallVoiceWay.device || effect == _effect)))) return;
    _on = want;
    _running = way;
    _effect = want && way == CallVoiceWay.device ? effect : null;
    _cutter.reset();
    _waiting.clear();
    _problem = null;
    _behind = Duration.zero;
    final phrases = want && way == CallVoiceWay.elevenlabs;
    await setEffect(_effect?.name ?? 'none');
    await setLive(phrases);
    _tick?.cancel();
    // ElevenLabs reads what was said ten times a second; an effect only looks each second that it should still be
    // on (the plugin removed, the call left).
    _tick = !want
        ? null
        : phrases
            ? Timer.periodic(const Duration(milliseconds: 100), (_) => unawaited(_read()))
            : Timer.periodic(const Duration(seconds: 1), (_) {
                if (!_shouldRun()) unawaited(follow());
              });
    notifyListeners();
  }

  /// For a test: one reading, as the timer does.
  @visibleForTesting
  Future<void> readOnce() => _read();

  /// Takes what the microphone said since the last reading, cuts it into phrases and starts sending them.
  Future<void> _read() async {
    if (!_on || _running != CallVoiceWay.elevenlabs) return;
    if (!_shouldRun()) {
      await follow();
      return;
    }
    final pcm = await take();
    if (pcm.isEmpty) return;
    // Said while muted: let go, never sent.
    if (_muted()) {
      _cutter.reset();
      return;
    }
    for (final phrase in _cutter.add(pcm)) {
      _waiting.add(phrase);
      // Behind by more than three phrases: the oldest is dropped, so the call stays near what is being said.
      while (_waiting.length > 3) {
        _waiting.removeAt(0);
      }
    }
    unawaited(_send());
  }

  /// Sends the phrases waiting to ElevenLabs, one at a time and in order, and feeds each changed one into the call. A
  /// phrase that could not be changed is dropped and [problem] says why.
  Future<void> _send() async {
    if (_sending || _waiting.isEmpty) return;
    _sending = true;
    notifyListeners();
    try {
      while (_waiting.isNotEmpty && _on) {
        final phrase = _waiting.removeAt(0);
        final began = DateTime.now();
        try {
          final changed = await _convert(wav(phrase, PhraseCutter.rate));
          if (!_on) break;
          await feed(changed, VoiceChanger.liveRate);
          _behind = DateTime.now().difference(began) + Duration(milliseconds: phrase.length ~/ 2 * 1000 ~/ PhraseCutter.rate);
          if (_problem != null) _problem = null;
        } on VoiceChangerProblem catch (e) {
          _problem = e.words;
        } catch (e) {
          _problem = '$e';
        }
        notifyListeners();
      }
    } finally {
      _sending = false;
      notifyListeners();
    }
  }

  /// Back to one's own voice in the call: live changing turned off in the settings.
  Future<void> stop() async {
    VoiceChanger.instance.setLive(false);
    await follow();
  }

  /// [pcm] (16-bit little-endian mono at [rate]) as a WAV file's bytes.
  static Uint8List wav(Uint8List pcm, int rate) {
    final out = BytesBuilder(copy: false);
    final h = ByteData(44);
    void tag(int at, String s) {
      for (var i = 0; i < 4; i++) {
        h.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    h.setUint32(4, 36 + pcm.length, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    h.setUint32(16, 16, Endian.little);
    h.setUint16(20, 1, Endian.little);
    h.setUint16(22, 1, Endian.little);
    h.setUint32(24, rate, Endian.little);
    h.setUint32(28, rate * 2, Endian.little);
    h.setUint16(32, 2, Endian.little);
    h.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    h.setUint32(40, pcm.length, Endian.little);
    out.add(h.buffer.asUint8List());
    out.add(pcm);
    return out.takeBytes();
  }
}

/// Cuts what the microphone says into phrases: from a little before speech starts to a pause after it (or
/// [longest] at most), 16-bit little-endian mono at [rate]. A blip shorter than [shortest] of speech is not a phrase.
class PhraseCutter {
  /// Samples a second, as the microphone engine gives them (VoiceFx.take).
  static const rate = 16000;

  /// 20 ms: what loudness is judged over.
  static const _step = rate ~/ 50;

  /// Speech is louder than this (RMS, of 32768).
  static const speaking = 450.0;

  /// How much from before speech starts is kept with a phrase, the quiet that ends one, the least speech that makes
  /// one, and the longest one runs before it is cut anyway.
  static const before = Duration(milliseconds: 250);
  static const pause = Duration(milliseconds: 550);
  static const shortest = Duration(milliseconds: 250);
  static const longest = Duration(seconds: 4);

  static int _samples(Duration d) => rate * d.inMilliseconds ~/ 1000;

  // The samples just heard while nobody speaks ([before] of them), the phrase being made, and the 20 ms being
  // gathered; whether a phrase is being made, and how much of it so far was quiet since speech and how much speech.
  final List<int> _pre = [];
  final List<int> _phrase = [];
  final List<int> _part = [];
  bool _in = false;
  int _quiet = 0, _spoken = 0;

  /// Lets go of everything heard so far: a phrase half made is never finished.
  void reset() {
    _pre.clear();
    _phrase.clear();
    _part.clear();
    _in = false;
    _quiet = 0;
    _spoken = 0;
  }

  /// The phrases [pcm] completes.
  List<Uint8List> add(Uint8List pcm) {
    final out = <Uint8List>[];
    final data = ByteData.sublistView(pcm);
    for (var i = 0; i + 1 < pcm.length; i += 2) {
      _part.add(data.getInt16(i, Endian.little));
      if (_part.length < _step) continue;
      var sum = 0.0;
      for (final s in _part) {
        sum += s * s;
      }
      final loud = math.sqrt(sum / _part.length) > speaking;
      if (!_in) {
        _pre.addAll(_part);
        final keep = _samples(before);
        if (_pre.length > keep) _pre.removeRange(0, _pre.length - keep);
        if (loud) {
          _in = true;
          _phrase.addAll(_pre);
          _pre.clear();
          _spoken = _part.length;
          _quiet = 0;
        }
      } else {
        _phrase.addAll(_part);
        if (loud) {
          _spoken += _part.length;
          _quiet = 0;
        } else {
          _quiet += _part.length;
        }
        if (_quiet >= _samples(pause) || _phrase.length >= _samples(longest)) {
          if (_spoken >= _samples(shortest)) out.add(_bytes(_phrase));
          _phrase.clear();
          _in = false;
          _quiet = 0;
          _spoken = 0;
        }
      }
      _part.clear();
    }
    return out;
  }

  static Uint8List _bytes(List<int> samples) {
    final b = ByteData(samples.length * 2);
    for (var i = 0; i < samples.length; i++) {
      b.setInt16(i * 2, samples[i], Endian.little);
    }
    return b.buffer.asUint8List();
  }
}
