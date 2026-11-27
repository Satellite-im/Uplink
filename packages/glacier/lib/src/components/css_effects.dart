import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../tokens/css_value.dart';
import '../tokens/theme.dart';
import '../tokens/tokens.dart';
import '../plain.dart';

// What a stylesheet paints that Flutter's BoxDecoration does not, shared by the components that need it (the switch,
// the segmented control, the pill, the toast): the inset layers of a `box-shadow`, the outer layers kept out from
// under a see-through box, and `backdrop-filter`. Not part of the kit's public surface.

/// Every layer of a `box-shadow` as a rule writes it,
/// `inset 0 var(--glacier-hairline) 0 var(--glacier-glass-highlight), var(--glacier-shadow-2)`, with the tokens in it
/// resolved. [Tokens.shadowOf] gives the outer layers alone.
List<CssShadow> cssShadowsOf(Tokens tokens, String expression) => evalShadows(tokens.resolve(expression), ctx: tokens.css);

/// Picks the outer layers out of a `box-shadow`'s layers, as Flutter shadows.
extension CssShadowLayers on List<CssShadow> {
  /// The layers [BoxDecoration.boxShadow] draws.
  List<BoxShadow> get outer => [
        for (final shadow in this)
          if (!shadow.inset) shadow.toBoxShadow(),
      ];
}

/// The inset layers of a `box-shadow`, drawn inside a box's rounded edge: over its background and under [child].
/// Put it inside the border, with the padding box's radius.
class GlacierInsetShadows extends StatelessWidget {
  const GlacierInsetShadows({super.key, required this.shadows, required this.radius, this.child});

  /// Any layers; the outer ones are skipped.
  final List<CssShadow> shadows;
  final double radius;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final inset = [
      for (final shadow in shadows)
        if (shadow.inset && shadow.color.a > 0) shadow,
    ];
    if (inset.isEmpty) return child ?? const SizedBox.shrink();
    return CustomPaint(painter: _InsetPainter(inset, radius), child: child);
  }
}

/// Paints [GlacierInsetShadows]' layers, clipped to the rounded box.
class _InsetPainter extends CustomPainter {
  _InsetPainter(this.shadows, this.radius);
  final List<CssShadow> shadows;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final box = RRect.fromRectAndRadius(rect, Radius.circular(math.max(0, math.min(radius, size.shortestSide / 2))));
    canvas.save();
    canvas.clipRRect(box);
    // The first layer written is the top one.
    for (final shadow in shadows.reversed) {
      // What casts an inset shadow is everything outside the box, moved by the offset and grown by the spread: the
      // shadow is the part of the box that leaves uncovered.
      final hole = box.deflate(shadow.spread).shift(shadow.offset);
      final reach = shadow.blur + shadow.spread.abs() + shadow.offset.distance + 1;
      final paint = Paint()..color = shadow.color;
      if (shadow.blur > 0) paint.maskFilter = MaskFilter.blur(BlurStyle.normal, shadow.blur / 2);
      canvas.drawDRRect(RRect.fromRectAndRadius(rect.inflate(reach), Radius.zero), hole, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_InsetPainter old) => old.radius != radius || !_same(old.shadows, shadows);

  static bool _same(List<CssShadow> a, List<CssShadow> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].offset != b[i].offset || a[i].blur != b[i].blur || a[i].spread != b[i].spread || a[i].color != b[i].color) return false;
    }
    return true;
  }
}

/// The outer layers of a `box-shadow` round [child], as CSS draws them: outside the box only. A [BoxDecoration]
/// paints its shadow under the whole box, which is the same thing behind an opaque fill and a darker one behind
/// glass.
class GlacierOuterShadows extends StatelessWidget {
  const GlacierOuterShadows({super.key, required this.shadows, required this.radius, required this.child});

  /// Any layers; the inset ones are skipped.
  final List<CssShadow> shadows;
  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final outer = shadows.outer;
    if (outer.isEmpty) return child;
    return CustomPaint(painter: _OuterPainter(outer, radius), child: child);
  }
}

/// Paints [GlacierOuterShadows]' layers everywhere but inside the rounded box.
class _OuterPainter extends CustomPainter {
  _OuterPainter(this.shadows, this.radius);
  final List<BoxShadow> shadows;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final box = RRect.fromRectAndRadius(rect, Radius.circular(math.max(0, math.min(radius, size.shortestSide / 2))));
    var reach = 0.0;
    for (final shadow in shadows) {
      reach = math.max(reach, shadow.offset.distance + shadow.spreadRadius.abs() + shadow.blurRadius * 2 + 1);
    }
    canvas.save();
    // Everywhere the shadows could fall, less the box itself.
    canvas.clipPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(rect.inflate(reach))
        ..addRRect(box),
    );
    for (final shadow in shadows) {
      canvas.drawRRect(box.shift(shadow.offset).inflate(shadow.spreadRadius), shadow.toPaint());
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OuterPainter old) => old.radius != radius || !_sameList(old.shadows, shadows);

  static bool _sameList(List<BoxShadow> a, List<BoxShadow> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// `backdrop-filter: blur(var(--glacier-blur-sm)) saturate(var(--glacier-glass-saturate))` behind [child], within its
/// rounded box. The filter is laid under the child rather than round it, so what the child draws outside its own box
/// (a shadow, a focus ring) is not clipped, as it is not on the page.
class GlacierBackdrop extends StatelessWidget {
  const GlacierBackdrop({super.key, required this.radius, this.enabled = true, required this.child});

  final double radius;

  /// False and this is [child] alone.
  final bool enabled;
  final Widget child;

  /// The colour matrix of CSS's `saturate()`.
  static List<double> _saturate(double s) => [
        0.213 + 0.787 * s, 0.715 - 0.715 * s, 0.072 - 0.072 * s, 0, 0, //
        0.213 - 0.213 * s, 0.715 + 0.285 * s, 0.072 - 0.072 * s, 0, 0, //
        0.213 - 0.213 * s, 0.715 - 0.715 * s, 0.072 + 0.928 * s, 0, 0, //
        0, 0, 0, 1, 0,
      ];

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    final tokens = GlacierTheme.of(context);
    final sigma = tokens.len('glacier-blur-sm');
    final filter = ui.ImageFilter.compose(
      outer: ColorFilter.matrix(_saturate(tokens.len('glacier-glass-saturate'))),
      inner: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
    );
    return Stack(
      fit: StackFit.passthrough,
      alignment: Alignment.topLeft,
      children: [
        Positioned.fill(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: BackdropFilter(enabled: !glacierPlain, filter: filter, child: const SizedBox.expand()),
          ),
        ),
        child,
      ],
    );
  }
}
