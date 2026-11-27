import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../kit/settings_type.dart';
import '../kit/semantic_colors.dart';
import 'dialup/parts.dart' show VoiceFace, voiceCorner;

/// A face in a call, with wobbly rings going out from it while they talk (Matt, 2026-11-15: "make the profile
/// picture habe wobbly ripples going out when talking"). [level] is how loud they are now, 0 to 1 (lib/voice/rtc.dart
/// reads it from WebRTC): the rings come and go with it, wobble more the louder it is, and are still when quiet.
class RippleAvatar extends StatelessWidget {
  const RippleAvatar({super.key, required this.name, required this.level, this.size = 44, this.color, this.muted = false, this.ringed = false, this.child});

  /// Drawn as the face in the initial's place, where given: their picture (lib/ui/open_space_view.dart). It is clipped
  /// to the face's shape.
  final Widget? child;

  /// A green ring round the face even while quiet: a call that is on.
  final bool ringed;
  final String name;
  final double level;
  final double size;
  final Color? color;
  final bool muted;

  /// Louder than this is talking.
  static const talking = 0.04;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final ink = color ?? t.online;
    final letter = (name.replaceAll('@', '').trim().characters.firstOrNull ?? '?').toUpperCase();
    // Dial-Up's and Runestone's: square, or a squircle in the pack's frame, and the rings and the green line with it
    // (lib/ui/dialup/parts.dart's voiceCorner).
    final corner = voiceCorner(t, size);
    if (corner != null) {
      final face = VoiceFace(
        size: size,
        child: child ?? ColoredBox(color: t.color('app-paper-3'), child: Center(child: Text(letter, style: pageText(t, size * 0.4, weight: 'bold', color: t.color('app-ink'))))),
      );
      return SizedBox.square(
        dimension: size,
        child: VoiceRipples(
          level: level,
          muted: muted,
          color: ink,
          reach: size / 2 * 0.6,
          corner: corner,
          builder: (context, strength) => strength <= 0.05 && !ringed
              ? face
              : TalkingLine(corner: corner, color: strength > 0.05 ? ink.withValues(alpha: (0.4 + strength * 0.6).clamp(0, 1)) : ink, width: 2.5, child: face),
        ),
      );
    }
    // As big as the face: the rings spill past it, over what is around, rather than holding a row apart.
    return SizedBox.square(
      dimension: size,
      child: VoiceRipples(
        level: level,
        muted: muted,
        color: ink,
        reach: size / 2 * 0.85,
        builder: (context, strength) => OverflowBox(
          maxWidth: size,
          maxHeight: size,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: t.color('app-paper-3'),
              border: Border.all(color: strength > 0.05 ? ink.withValues(alpha: (0.4 + strength * 0.6).clamp(0, 1)) : (ringed ? ink : t.color('app-rule')), width: strength > 0.05 || ringed ? 2.5 : 1),
            ),
            alignment: Alignment.center,
            clipBehavior: child == null ? Clip.none : Clip.antiAlias,
            child: child ?? Text(letter, style: pageText(t, size * 0.4, weight: 'bold', color: t.color('app-ink'))),
          ),
        ),
      ),
    );
  }
}

/// The green line round a square or squircle face ([corner], as lib/ui/dialup/parts.dart's voiceCorner gives it) that
/// is talking or in a call. On a square it is over the face's edge; round a squircle, which is in a resource pack's
/// textured frame, it is just outside it, so the frame is still seen, and takes no room there.
class TalkingLine extends StatelessWidget {
  const TalkingLine({super.key, required this.corner, required this.color, required this.width, required this.child});
  final double corner;
  final Color color;
  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final out = corner > 0 ? width : 0.0;
    return Stack(clipBehavior: Clip.none, children: [
      child,
      Positioned(
        left: -out,
        top: -out,
        right: -out,
        bottom: -out,
        child: IgnorePointer(child: DecoratedBox(decoration: BoxDecoration(borderRadius: BorderRadius.circular(corner > 0 ? corner + out : 0), border: Border.all(color: color, width: width)))),
      ),
    ]);
  }
}

/// Wobbly rings going out from [builder]'s child while someone talks, whatever its shape: a face's circle (no [corner]),
/// or a tile with rounded corners ([corner]). Everywhere someone's talking is drawn, it is these (Matt, 2026-11-25: "make
/// sure everywhere voice activity is logged uses the ripple animation"). They spill past the child by up to [reach] and
/// take no room. [builder] is told how strongly they are drawn now, 0 to 1.
class VoiceRipples extends StatefulWidget {
  const VoiceRipples({super.key, required this.level, required this.builder, required this.reach, this.muted = false, this.color, this.corner});
  final double level;
  final bool muted;
  final Color? color;
  final double reach;
  final double? corner;
  final Widget Function(BuildContext context, double strength) builder;

  @override
  State<VoiceRipples> createState() => _VoiceRipplesState();
}

class _VoiceRipplesState extends State<VoiceRipples> with SingleTickerProviderStateMixin {
  late final AnimationController _time = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));
  double _strength = 0;

  @override
  void didUpdateWidget(VoiceRipples old) {
    super.didUpdateWidget(old);
    _follow();
  }

  @override
  void initState() {
    super.initState();
    _follow();
  }

  /// Runs the rings' clock while they talk, and stops it once the rings have faded.
  void _follow() {
    final speaking = !widget.muted && widget.level > RippleAvatar.talking;
    if (speaking && !_time.isAnimating) _time.repeat();
    // The rings fade out by themselves once quiet; the clock stops when they are gone.
    if (!speaking && _strength < 0.02 && _time.isAnimating) _time.stop();
  }

  @override
  void dispose() {
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ink = widget.color ?? context.tokens.online;
    final want = widget.muted ? 0.0 : (widget.level <= RippleAvatar.talking ? 0.0 : (0.35 + widget.level * 1.6).clamp(0.0, 1.0));
    return AnimatedBuilder(
      animation: _time,
      builder: (context, _) {
        // Eased towards how loud they are, frame by frame.
        _strength += (want - _strength) * (want > _strength ? 0.35 : 0.08);
        if (_strength < 0.02 && want == 0 && _time.isAnimating) WidgetsBinding.instance.addPostFrameCallback((_) => _follow());
        return CustomPaint(
          painter: _Ripples(time: _time.value, strength: _strength, color: ink, reach: widget.reach, corner: widget.corner),
          child: widget.builder(context, _strength),
        );
      },
    );
  }
}

/// Three rings going out from the child's edge by [reach], one after another: [time] is 0 to 1 round the loop, [strength]
/// how strongly they are drawn. A circle's, or with [corner] a rounded rectangle's.
class _Ripples extends CustomPainter {
  _Ripples({required this.time, required this.strength, required this.color, required this.reach, this.corner});
  final double time;
  final double strength;
  final Color color;
  final double reach;
  final double? corner;

  @override
  void paint(Canvas canvas, Size size) {
    if (strength < 0.02) return;
    final c = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    const rings = 3;
    for (var i = 0; i < rings; i++) {
      // Each ring goes out and fades, a third of the way behind the one before.
      final phase = (time + i / rings) % 1.0;
      final out = phase * reach;
      final wobble = 0.06 * strength * (1 - phase * 0.5);
      final path = Path();
      final round = corner;
      if (round == null) {
        final r = radius + out;
        const steps = 64;
        for (var s = 0; s <= steps; s++) {
          final a = s / steps * math.pi * 2;
          // Two waves going round at different speeds: a wobble, not a gear.
          final d = r * (1 + wobble * math.sin(a * 5 + time * math.pi * 4 + i) + wobble * 0.6 * math.sin(a * 3 - time * math.pi * 6));
          final p = c + Offset(math.cos(a) * d, math.sin(a) * d);
          s == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
        }
      } else {
        // The same two waves along a rounded rectangle's edge, as far in and out as the rings have room for.
        final edge = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(round)).inflate(out));
        final m = edge.computeMetrics().first;
        // Fewer, gentler waves round something as small as a face: many of them would be spikes there.
        final small = size.shortestSide < 60, fast = small ? 5 : 9, slow = small ? 3 : 5;
        const steps = 240;
        for (var s = 0; s < steps; s++) {
          final at = m.getTangentForOffset(m.length * s / steps)!, a = s / steps * math.pi * 2;
          final d = reach * wobble * (small ? 2 : 4) * (math.sin(a * fast + time * math.pi * 4 + i) + 0.6 * math.sin(a * slow - time * math.pi * 6));
          final p = at.position + Offset(-at.vector.dy, at.vector.dx) * d;
          s == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
        }
      }
      path.close();
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2 * (1 - phase) + 0.6
          ..color = color.withValues(alpha: (1 - phase) * 0.7 * strength),
      );
    }
  }

  @override
  bool shouldRepaint(_Ripples old) => old.time != time || old.strength != strength || old.color != color || old.reach != reach || old.corner != corner;
}
