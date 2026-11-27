/// A field of colour with a sign in the middle and glass tiles drifting round it: Ghost.md's walkthrough band (its
/// lib/guide/pages/band.dart `HueBand`), by way of Ghost Keyboard's lib/onboarding/band.dart (Matt, 2026-11-15: "Look at
/// how we do onboarding on Ghost KBD and Ghost Markdown ... mimick this on the setup of Ghost Messaging"). The drift's
/// pace is fixed (six seconds a turn) and stills for a person who asked for less motion.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';

const Color _white = Color(0xFFFFFFFF);

/// Each hue, as Ghost.md's settings.css writes it: the deep shade, then the bright one (Ghost Keyboard's Market table).
/// The band draws the deep shade, on either theme.
const Map<String, (Color, Color)> guideHues = {
  'blue': (Color(0xFF0A6FE0), Color(0xFF4EA1FF)),
  'purple': (Color(0xFF9A45C9), Color(0xFFC77DFF)),
  'red': (Color(0xFFDD3A30), Color(0xFFFF6B61)),
  'coral': (Color(0xFFC8643F), Color(0xFFF0906B)),
  'green': (Color(0xFF2A9D4B), Color(0xFF4CD571)),
  'yellow': (Color(0xFFB58400), Color(0xFFFFD43B)),
  'mint': (Color(0xFF1F9E8F), Color(0xFF5FE0CF)),
  'amber': (Color(0xFFC27C00), Color(0xFFFFB84D)),
  'indigo': (Color(0xFF4F5BD5), Color(0xFF8C95FF)),
  'orange': (Color(0xFFD9600D), Color(0xFFFF9A4D)),
  'cyan': (Color(0xFF0A86A8), Color(0xFF4CC9F0)),
  'lime': (Color(0xFF5A8A00), Color(0xFFA3D93F)),
  'rose': (Color(0xFFD6336C), Color(0xFFFF7AA8)),
  'magenta': (Color(0xFFB5279F), Color(0xFFF07AE0)),
  'slate': (Color(0xFF4A5A70), Color(0xFF8FA3BF)),
};

/// The light over the band: a glow from the top start corner.
Widget tileLight({required double radius}) => IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          gradient: const RadialGradient(center: Alignment(-0.8, -0.9), radius: 1.1, colors: [Color(0x40FFFFFF), Color(0x00FFFFFF)]),
        ),
        child: const SizedBox.expand(),
      ),
    );

/// Each hue's deep shade, by the names [guideHues] keeps.
List<Color> hueColours(List<String> hues) => [for (final hue in hues) guideHues[hue]!.$1];

/// Where each tile floats: its centre across and down (0 to 1), its size as a share of the band's height, its turn.
const List<(double, double, double, double)> _spots = [
  (0.16, 0.24, 0.24, -0.12),
  (0.85, 0.30, 0.20, 0.10),
  (0.82, 0.78, 0.22, -0.06),
  (0.14, 0.76, 0.18, 0.14),
];

/// A tile's mark: [icon] in white, half the tile across.
Widget Function(double size) bandIcon(LucideIcon icon) => (size) => AppIcon(icon, size: size * 0.5, strokeWidth: 2.2, color: _white);

/// The usual sign: a large [icon] on a disc of glass.
Widget bandDisc(LucideIcon icon, {required double height, required double width}) {
  final side = math.min(height * 0.46, width * 0.36);
  return Container(
    width: side,
    height: side,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: const Color(0x33FFFFFF),
      border: Border.all(color: const Color(0x59FFFFFF), width: 1.5),
      boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 30, offset: Offset(0, 12))],
    ),
    child: AppIcon(icon, size: side * 0.5, strokeWidth: 2, color: _white),
  );
}

/// The band itself: a rounded field washed with [colours] from its top left to its bottom right, the sign in its
/// middle, and up to four tiles floating at [_spots]. Decoration only: a screen reader is told nothing of it.
class HueBand extends StatefulWidget {
  const HueBand({super.key, required this.colours, required this.height, required this.sign, this.tiles = const []});

  /// The wash's colours, two or more.
  final List<Color> colours;
  final double height;

  /// Builds the sign for a band of this height and width ([bandDisc] is the usual one).
  final Widget Function(double height, double width) sign;

  /// Each tile's mark, built for the tile's size ([bandIcon]).
  final List<Widget Function(double size)> tiles;

  @override
  State<HueBand> createState() => _HueBandState();
}

class _HueBandState extends State<HueBand> with SingleTickerProviderStateMixin {
  /// One turn of the drift, over and over: the tiles bob on it and the sign breathes with it.
  late final AnimationController _drift = AnimationController(vsync: this, duration: const Duration(seconds: 6));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (context.tokens.reducedMotion) {
      _drift
        ..stop()
        ..value = 0;
    } else if (!_drift.isAnimating) {
      _drift.repeat();
    }
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final height = widget.height;
    final radius = t.radius('lg') * 1.6;
    final colours = widget.colours;
    final tiles = widget.tiles.take(_spots.length).toList();
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: SizedBox(
          height: height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: AlignmentDirectional.topStart,
                end: AlignmentDirectional.bottomEnd,
                colors: colours,
                stops: [for (var i = 0; i < colours.length; i++) i / (colours.length - 1)],
              ),
            ),
            child: LayoutBuilder(
              builder: (context, box) {
                final width = box.maxWidth;
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(child: tileLight(radius: radius)),
                    for (var i = 0; i < tiles.length; i++) _tile(i, tiles[i], width: width, height: height),
                    Center(child: _breathing(widget.sign(height, width))),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// The [i]th tile: a square of glass at its spot, bobbing five pixels up and down, each a little out of step
  /// with the last.
  Widget _tile(int i, Widget Function(double) mark, {required double width, required double height}) {
    final (x, y, share, turn) = _spots[i];
    final size = math.min(height * share, width * 0.2);
    final glass = Transform.rotate(
      angle: turn,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0x2EFFFFFF),
          borderRadius: BorderRadius.circular(size * 0.28),
          border: Border.all(color: const Color(0x40FFFFFF)),
          boxShadow: const [BoxShadow(color: Color(0x26000000), blurRadius: 14, offset: Offset(0, 6))],
        ),
        child: mark(size),
      ),
    );
    return PositionedDirectional(
      start: x * width - size / 2,
      top: y * height - size / 2,
      child: AnimatedBuilder(
        animation: _drift,
        child: glass,
        builder: (context, child) => Transform.translate(offset: Offset(0, 5 * math.sin(2 * math.pi * (_drift.value + i * 0.23))), child: child),
      ),
    );
  }

  /// The sign, growing and shrinking by a fortieth of its size with the drift.
  Widget _breathing(Widget sign) => AnimatedBuilder(
        animation: _drift,
        child: sign,
        builder: (context, child) => Transform.scale(scale: 1 + 0.025 * math.sin(2 * math.pi * _drift.value), child: child),
      );
}
