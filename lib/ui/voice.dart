import 'dart:async';
import '../platform_info.dart';
import 'dart:math' as math;

import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey, PlatformException;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../kit/settings_type.dart';
import '../sms.dart';
import 'common.dart';
import '../kit/semantic_colors.dart';

/// Voice messages on the screen (Matt, 2026-11-13: "I also want to have the ability to send audio messages"): the
/// row the composer becomes while one is being recorded, and the player a message's sound is drawn as. The phone's
/// half is android/.../Voice.kt.

/// 67 seconds as `1:07`.
String voiceClock(Duration d) {
  final s = d.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// What went wrong, in the phone's own words where it gave some.
String voiceProblem(Object e) => e is PlatformException ? (e.message ?? '$e') : '$e';

/// What to do when the microphone was refused, in this device's own words (GMFB-32: a computer records too).
String micRefusedWords() {
  if (PlatformInfo.isMacOS) return 'Allow the microphone for Uplink in System Settings › Privacy & Security › Microphone to record a voice message.';
  if (PlatformInfo.isWindows) return 'Turn on microphone access for desktop apps in Windows Settings › Privacy & security › Microphone to record a voice message.';
  if (PlatformInfo.isIOS) return 'Allow the microphone for Uplink in the iPhone\'s Settings to record a voice message.';
  return 'Allow the microphone for Uplink in Android\'s settings to record a voice message.';
}

/// The composer while a voice message is being recorded: throw it away, how long it has run and how loud it is, send.
class VoiceRecorder extends StatefulWidget {
  const VoiceRecorder({super.key, required this.limit, required this.onDiscard, required this.onSend, this.note, this.carrier = true});

  /// The most seconds the recording may run: what fits in a message on this carrier.
  final int limit;
  final VoidCallback onDiscard;
  final VoidCallback onSend;

  /// A line under the row: that it is not encrypted, in a conversation that is.
  final String? note;

  /// A text, whose length the carrier holds; false for one that goes as a file (a network's chat, a space), whose
  /// length is the app's own.
  final bool carrier;

  @override
  State<VoiceRecorder> createState() => _VoiceRecorderState();
}

class _VoiceRecorderState extends State<VoiceRecorder> {
  /// How often the loudness is asked for, and how many of the latest readings are kept for the picture of it.
  static const _beat = Duration(milliseconds: 100);
  static const _kept = 64;
  final _watch = Stopwatch()..start();
  final List<double> _levels = [];
  Timer? _timer;
  StreamSubscription<void>? _fullSub;
  int _beats = 0;
  bool _full = false;

  /// Holds the keyboard while it records: the message field it took the place of had it.
  final _keys = FocusNode(debugLabel: 'voice recorder');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _keys.requestFocus();
    });
    _timer = Timer.periodic(_beat, (_) => _tick());
    _fullSub = Sms.instance.voiceFull.stream.listen((_) => _fill());
  }

  @override
  void dispose() {
    _keys.dispose();
    _timer?.cancel();
    _fullSub?.cancel();
    super.dispose();
  }

  /// How long it has run: the clock's word for it, and never less than the beats counted.
  Duration get _elapsed {
    final counted = _beat * _beats;
    final run = _watch.elapsed > counted ? _watch.elapsed : counted;
    final most = Duration(seconds: widget.limit);
    return run > most ? most : run;
  }

  /// The recording has reached the most it may be (the phone said so, or the clock here did): the clock stops, and
  /// the row says why.
  void _fill() {
    if (_full || !mounted) return;
    _watch.stop();
    setState(() => _full = true);
  }

  /// Every beat: counts it, stops at the limit, and otherwise adds the microphone's level now to the readings.
  Future<void> _tick() async {
    if (_full) return;
    _beats++;
    if (_elapsed >= Duration(seconds: widget.limit)) return _fill();
    double level;
    try {
      level = await Sms.instance.voiceLevel();
    } catch (_) {
      level = 0;
    }
    if (!mounted) return;
    setState(() {
      _levels.add(level);
      if (_levels.length > _kept) _levels.removeAt(0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final red = t.danger;
    final note = _full ? (widget.carrier ? 'That\'s as long as a voice message can be on your carrier.' : 'That\'s as long as a voice message can be.') : widget.note;
    // On a computer the keyboard does it too (GMFB-32): Escape throws it away, Enter sends it.
    return Focus(
      focusNode: _keys,
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          widget.onDiscard();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
          widget.onSend();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        IconTap(icon: Lucide.trash2, label: 'Discard the recording', onPressed: widget.onDiscard),
        SizedBox(width: t.space(1)),
        Expanded(
          child: Container(
            constraints: BoxConstraints(minHeight: t.lenOf('2.75rem')),
            padding: EdgeInsetsDirectional.only(start: t.space(4), end: t.lenOf('0.25rem'), top: t.lenOf('0.25rem'), bottom: t.lenOf('0.25rem')),
            decoration: BoxDecoration(color: t.color('app-paper-2'), borderRadius: BorderRadius.circular(t.lenOf('1.375rem'))),
            child: Row(children: [
              Semantics(
                label: _full ? 'Recording stopped at ${voiceClock(_elapsed)}' : 'Recording, ${voiceClock(_elapsed)}',
                excludeSemantics: true,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: t.lenOf('0.6rem'),
                    height: t.lenOf('0.6rem'),
                    decoration: BoxDecoration(shape: BoxShape.circle, color: _full ? t.color('app-ink-3') : red),
                  ),
                  SizedBox(width: t.space(2)),
                  SizedBox(
                    width: t.lenOf('2.6rem'),
                    child: Text(voiceClock(_elapsed), style: pageText(t, t.fontSize('md'), weight: 'medium', color: t.color('app-ink'))),
                  ),
                ]),
              ),
              Expanded(
                child: SizedBox(
                  height: t.lenOf('1.6rem'),
                  child: CustomPaint(painter: _LevelsPainter(List<double>.of(_levels), t.color('app-ink-2'))),
                ),
              ),
              SizedBox(width: t.space(2)),
              Text(voiceClock(Duration(seconds: widget.limit)), style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
              SizedBox(width: t.space(2)),
              IconTap(icon: Lucide.send, label: 'Send voice message', filled: true, size: 16, box: t.lenOf('2.25rem'), onPressed: widget.onSend),
            ]),
          ),
        ),
        SizedBox(width: t.space(1)),
      ]),
      if (note != null)
        Padding(
          padding: EdgeInsetsDirectional.only(top: t.space(1), start: t.space(3), end: t.space(3)),
          child: Text(note, textAlign: TextAlign.end, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
        ),
    ]),
    );
  }
}

/// How loud the last few seconds were: one bar a beat, the newest at the right.
class _LevelsPainter extends CustomPainter {
  _LevelsPainter(this.levels, this.ink);
  final List<double> levels;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    const step = 5.0;
    const width = 3.0;
    final room = (size.width / step).floor();
    final shown = levels.length > room ? levels.sublist(levels.length - room) : levels;
    final paint = Paint()..color = ink;
    var x = size.width - shown.length * step;
    for (final level in shown) {
      // Speech sits low on a microphone's scale: the root brings it up where it can be seen.
      final h = math.max(3.0, math.sqrt(level.clamp(0.0, 1.0)) * size.height);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, (size.height - h) / 2, width, h), const Radius.circular(1.5)), paint);
      x += step;
    }
  }

  @override
  bool shouldRepaint(_LevelsPainter old) => true;
}

/// A voice message in the conversation: play and pause, how far through it is, how long it runs. On a computer
/// ([playable] false) it is named and no more: the sound stays on the phone.
class VoiceBubble extends StatefulWidget {
  const VoiceBubble({super.key, required this.part, required this.ground, required this.ink, required this.radius, this.rim, this.playable = true});
  final int part;
  final Color ground;
  final Color ink;
  final BorderRadius radius;
  final BoxBorder? rim;
  final bool playable;

  @override
  State<VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<VoiceBubble> {
  StreamSubscription<VoicePlayback>? _sub;
  Duration _length = Duration.zero;
  Duration _at = Duration.zero;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    if (!widget.playable) return;
    _askLength();
    _sub = Sms.instance.voice.stream.listen(_heard);
  }

  /// A conversation's list hands this place to another message when one arrives above it: what was known was the
  /// other one's, so it is asked again. (Without this every voice message wore the length of the first one drawn.)
  @override
  void didUpdateWidget(VoiceBubble old) {
    super.didUpdateWidget(old);
    if (old.part == widget.part) return;
    _length = Duration.zero;
    _at = Duration.zero;
    _playing = false;
    if (widget.playable) _askLength();
  }

  void _askLength() {
    final part = widget.part;
    Sms.instance.voiceLength(part).then((d) {
      if (mounted && widget.part == part && d > Duration.zero && _length == Duration.zero) setState(() => _length = d);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  /// The phone's word on what is playing, sent to every player: only the one whose part it names follows it.
  void _heard(VoicePlayback v) {
    if (v.part != widget.part) {
      // Another one is playing now: this one is back at its start.
      if (_playing || _at > Duration.zero) setState(() { _playing = false; _at = Duration.zero; });
      return;
    }
    setState(() {
      _playing = v.playing;
      _at = v.position;
      if (v.length > Duration.zero) _length = v.length;
    });
  }

  Future<void> _toggle() async {
    try {
      if (_playing) {
        await Sms.instance.pauseVoice();
      } else {
        await Sms.instance.playVoice(widget.part);
      }
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t play it: ${voiceProblem(e)}', tone: GlacierToastTone.danger);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final ink = widget.ink;
    final under = _playing || _at > Duration.zero;
    final said = !widget.playable || (_length == Duration.zero && !under) ? 'Voice message' : voiceClock(under ? _at : _length);
    final through = _length > Duration.zero ? (_at.inMilliseconds / _length.inMilliseconds).clamp(0.0, 1.0) : 0.0;
    final disc = t.lenOf('2.25rem');
    return Container(
      width: widget.playable ? t.lenOf('14rem') : null,
      padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: t.space(2)),
      decoration: BoxDecoration(color: widget.ground, borderRadius: widget.radius, border: widget.rim),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (widget.playable)
          GlacierPressable(
            onPressed: _toggle,
            semanticLabel: _playing ? 'Pause voice message' : 'Play voice message',
            builder: (context, state) => Container(
              width: disc,
              height: disc,
              alignment: Alignment.center,
              decoration: BoxDecoration(shape: BoxShape.circle, color: ink.withValues(alpha: state.pressed ? 0.26 : 0.14)),
              child: AppIcon(_playing ? Lucide.pause : Lucide.play, size: 16, color: ink),
            ),
          )
        else
          Padding(padding: EdgeInsets.symmetric(horizontal: t.space(1)), child: AppIcon(Lucide.mic, size: 16, color: ink, wash: false)),
        SizedBox(width: t.space(2)),
        if (widget.playable) ...[
          Expanded(child: SizedBox(height: t.lenOf('1.25rem'), child: CustomPaint(painter: _TrackPainter(through, ink, knob: under)))),
          SizedBox(width: t.space(3)),
        ],
        Padding(
          padding: EdgeInsetsDirectional.only(end: t.space(2)),
          child: Text(said, style: pageText(t, t.fontSize('sm'), weight: 'medium', color: ink)),
        ),
      ]),
    );
  }
}

/// How far through the sound is: a line, the part played drawn full, a dot where it has got to.
class _TrackPainter extends CustomPainter {
  _TrackPainter(this.through, this.ink, {required this.knob});
  final double through;
  final Color ink;
  final bool knob;

  @override
  void paint(Canvas canvas, Size size) {
    const thick = 4.0;
    final y = (size.height - thick) / 2;
    const r = Radius.circular(thick / 2);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, y, size.width, thick), r), Paint()..color = ink.withValues(alpha: 0.28));
    final played = size.width * through;
    if (played > 0) canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, y, played, thick), r), Paint()..color = ink);
    if (knob) canvas.drawCircle(Offset(played.clamp(5.0, size.width - 5.0), size.height / 2), 5, Paint()..color = ink);
  }

  @override
  bool shouldRepaint(_TrackPainter old) => old.through != through || old.ink != ink || old.knob != knob;
}
