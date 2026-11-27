import 'dart:ui' show SemanticsRole;

import 'package:flutter/widgets.dart';

import '../tokens/css_value.dart';
import '../tokens/theme.dart';

/// `size` of a [GlacierProgressBar]: the track's thickness, 0.375rem or 0.625rem.
enum GlacierProgressBarSize { sm, md }

/// `tone` of a [GlacierProgressBar]: the fill's colour family.
enum GlacierProgressBarTone { accent, success, warning, danger }

/// One sweep, or one pulse under reduced motion: `1.4s` in Progress.module.css.
const _turn = Duration(milliseconds: 1400);

/// Port of `@glacier/react`'s `ProgressBar` (`atoms/feedback/Progress/ProgressBar.tsx`, with the `.track`, `.fill` and
/// `.indeterminate` rules of `Progress.module.css`; the spinner in the same stylesheet is not part of this).
///
/// A full-width rounded track with a fill of [value] out of [max], whose width eases over the normal duration when the
/// value changes. With no value, or [indeterminate], a 40% fill sweeps across the track every 1.4s on the in-out
/// easing; under reduced motion the fill stands full and pulses between 0.3 and 0.7 opacity instead, as the
/// stylesheet's `prefers-reduced-motion` block has it.
///
/// What differs from the React original:
/// - `skeleton` is not ported.
/// - An unknown bar is announced as a loading spinner rather than a progress bar with no value, because Flutter's
///   progress-bar role requires one; a known bar carries `aria-valuemin`, `aria-valuemax` and `aria-valuenow` as its
///   minimum, maximum and value.
/// - The sweep runs from the start edge in a right-to-left layout, as `inset-inline-start` does.
class GlacierProgressBar extends StatefulWidget {
  const GlacierProgressBar({
    super.key,
    this.value,
    this.max = 100,
    this.indeterminate = false,
    this.size = GlacierProgressBarSize.md,
    this.tone = GlacierProgressBarTone.accent,
    this.ariaLabel,
  }) : assert(max > 0);

  /// 0 to [max]. Omit (or set [indeterminate]) for an unknown duration.
  final double? value;
  final double max;
  final bool indeterminate;
  final GlacierProgressBarSize size;
  final GlacierProgressBarTone tone;

  /// `aria-label`: the accessible name for the bar.
  final String? ariaLabel;

  @override
  State<GlacierProgressBar> createState() => _GlacierProgressBarState();
}

class _GlacierProgressBarState extends State<GlacierProgressBar> with SingleTickerProviderStateMixin {
  /// The clock of the sweep (or the pulse): runs only while the bar's value is unknown.
  late final AnimationController _loop = AnimationController(vsync: this, duration: _turn);

  bool get _unknown => widget.indeterminate || widget.value == null;

  @override
  void initState() {
    super.initState();
    if (_unknown) _loop.repeat();
  }

  @override
  void didUpdateWidget(GlacierProgressBar old) {
    super.didUpdateWidget(old);
    if (_unknown == _loop.isAnimating) return;
    if (_unknown) {
      _loop.repeat();
    } else {
      _loop
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  /// A number as an attribute would carry it: `40`, not `40.0`.
  static String _number(double n) => n == n.roundToDouble() ? n.round().toString() : n.toString();

  @override
  Widget build(BuildContext context) {
    final t = GlacierTheme.of(context);
    final unknown = _unknown;
    final clamped = unknown ? 0.0 : widget.value!.clamp(0.0, widget.max).toDouble();
    final radius = BorderRadius.circular(t.radius('full'));
    final color = t.color(switch (widget.tone) {
      GlacierProgressBarTone.accent => 'glacier-accent-solid',
      GlacierProgressBarTone.success => 'glacier-success-solid',
      GlacierProgressBarTone.warning => 'glacier-warning-solid',
      GlacierProgressBarTone.danger => 'glacier-danger-solid',
    });

    final Widget fill;
    if (!unknown) {
      fill = AnimatedFractionallySizedBox(
        duration: t.duration('glacier-duration-normal'),
        curve: t.curve('glacier-ease-out'),
        alignment: AlignmentDirectional.centerStart,
        widthFactor: clamped / widget.max,
        heightFactor: 1,
        child: DecoratedBox(decoration: BoxDecoration(color: color, borderRadius: radius)),
      );
    } else if (t.reducedMotion) {
      // `indeterminatePulse`: 0.3 at either end and 0.7 halfway, each half on the plain `ease-in-out`.
      final ease = evalCurve('ease-in-out');
      fill = AnimatedBuilder(
        animation: _loop,
        builder: (context, child) {
          final there = _loop.value < 0.5 ? _loop.value * 2 : (1 - _loop.value) * 2;
          final opacity = 0.3 + 0.4 * ease.transform(there);
          return SizedBox.expand(
            child: DecoratedBox(decoration: BoxDecoration(color: color.withValues(alpha: color.a * opacity), borderRadius: radius)),
          );
        },
      );
    } else {
      // `sweep`: the fill is 40% of the track, and its start edge runs from -40% to 100% of it.
      final ease = t.curve('glacier-ease-in-out');
      final rtl = Directionality.maybeOf(context) == TextDirection.rtl;
      fill = FractionallySizedBox(
        alignment: AlignmentDirectional.centerStart,
        widthFactor: 0.4,
        heightFactor: 1,
        child: AnimatedBuilder(
          animation: _loop,
          builder: (context, child) {
            final start = -0.4 + 1.4 * ease.transform(_loop.value);
            // A fractional translation is in the fill's own widths, and the fill is 0.4 of the track.
            return FractionalTranslation(translation: Offset((rtl ? -1 : 1) * start / 0.4, 0), child: child);
          },
          child: DecoratedBox(decoration: BoxDecoration(color: color, borderRadius: radius)),
        ),
      );
    }

    return Semantics(
      container: true,
      role: unknown ? SemanticsRole.loadingSpinner : SemanticsRole.progressBar,
      label: widget.ariaLabel,
      value: unknown ? null : _number(clamped),
      minValue: unknown ? null : '0',
      maxValue: unknown ? null : _number(widget.max),
      child: Container(
        width: double.infinity,
        height: t.lenOf(widget.size == GlacierProgressBarSize.sm ? '0.375rem' : '0.625rem'),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(color: t.color('glacier-segment-track'), borderRadius: radius),
        child: fill,
      ),
    );
  }
}
