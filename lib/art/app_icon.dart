import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart' show GlacierTheme;

import 'icon_wash.dart';
import 'pixel_icons.g.dart';
import 'svg_path.dart';

/// One of the app's icons. Since 2026-11-20 every one is Phosphor's duotone (Matt: "switch to using phosphor icons"),
/// made by tool/phosphor.mjs from tool/phosphor-map.json: [body], the shape filled at a fifth of the ink, and
/// [outline], filled in the whole ink, both on Phosphor's 256 grid. The code still calls each by its Lucide name
/// (`Lucide.search`), so nothing that names an icon had to change. The plain constructor, Lucide's stroked paths on
/// the 24 grid, is kept for a drawing of the app's own made the same way.
@immutable
class LucideIcon {
  const LucideIcon(this.name, this.shapes, this.wash) : body = null, outline = null;
  const LucideIcon.phosphor(this.name, this.body, String this.outline) : shapes = const [], wash = const [];

  /// Lucide's own name for it: the class its svg wears on the page, less `lucide-`, and the key in the docs' pages.
  final String name;

  /// A stroked drawing's paths on the 24 grid, and which of them wear the wash, by their place (icon_wash.dart).
  final List<String> shapes;
  final List<int> wash;

  /// Phosphor's: the duotone layer (empty for an icon with none) and the outline, filled.
  final String? body;
  final String? outline;
}

/// A lucide icon drawn the way the web app draws them: an outline in the text's own colour with round ends and
/// joins, at a stroke the caller chooses (often 2.1 or 2.2 on the page; lucide's own is 2), and inside it the wash,
/// a third of that colour on the icon's body alone (app.css "Icons are outlines, with a wash inside", iconWash.css).
///
/// `<Search size={18} strokeWidth={2.1} />` is `AppIcon(Lucide.search, size: 18, strokeWidth: 2.1)`. The size is
/// the svg's width and height; the stroke is in the icon's own 24 units and grows with the size, as lucide's does.
/// The colour is the `IconTheme`'s, else the text's (`currentColor`), unless [color] is given.
///
/// What differs from the page: nothing drawn; an icon font (`lucide_icons_flutter`, which the app carried until
/// nothing drew from it) has one fixed stroke and no wash, which is why these are drawn from the paths.
///
/// Ported from Ghost.md (lib/art/app_icon.dart) with its icon packs left out: Lucide's outline, always.
/// The icons that point a way, which [AppIcon] draws mirrored where the text runs right to left: arrows and chevrons
/// (back, forward, a row that opens a page), reply and send (which point along the line), undo, leaving, and a side
/// panel.
const mirrored = {'arrow-left', 'arrow-right', 'chevron-left', 'chevron-right', 'reply', 'send', 'undo-2', 'skip-forward', 'log-out', 'panel-left', 'external-link', 'square-arrow-out-up-right'};

class AppIcon extends StatelessWidget {
  const AppIcon(this.icon, {super.key, this.size = 24, this.strokeWidth = 2, this.color, this.wash = true, this.semanticLabel});

  final LucideIcon icon;
  final double size;
  final double strokeWidth;
  final Color? color;

  /// False draws the outline alone: an icon whose own stylesheet on the page says `fill: none`.
  final bool wash;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final ink = color ?? inkAt(context);
    final outline = icon.outline;
    // A look that draws its icons in square pixels (`--app-icons: pixel`, Runestone; Matt, 2026-11-27: "find a
    // pixelated icon pack to go with this theme"): the same icon from lib/art/pixel_icons.g.dart, filled on its 24
    // grid with hard edges, no wash and no stroke.
    final pixel = GlacierTheme.maybeOf(context)?.raw('app-icons')?.trim() == 'pixel' ? pixelIcons[icon.name] : null;
    final painter = pixel != null
        ? DrawnIconPainter(strokes: const [], washed: const [], fills: [pixel], color: ink, strokeWidth: strokeWidth, crisp: true)
        : outline != null
        ? DrawnIconPainter(
            strokes: const [],
            washed: wash && (icon.body ?? '').isNotEmpty ? [icon.body!] : const [],
            fills: [outline],
            washAlpha: phosphorWash,
            color: ink,
            strokeWidth: strokeWidth,
            viewBox: 256,
          )
        : DrawnIconPainter(strokes: icon.shapes, washed: wash ? [for (final index in icon.wash) icon.shapes[index]] : const [], color: ink, strokeWidth: strokeWidth);
    Widget picture = CustomPaint(size: Size.square(size), painter: painter);
    // An icon that points a way points the other in a language written right to left: back is to the right there.
    if (mirrored.contains(icon.name) && Directionality.maybeOf(context) == TextDirection.rtl) picture = Transform.flip(flipX: true, child: picture);
    if (semanticLabel == null) return ExcludeSemantics(child: picture);
    return Semantics(label: semanticLabel, image: true, child: picture);
  }
}

/// `currentColor` at [context]: the colour an icon theme set round it gives its icons, else the text's own. Only a
/// theme someone set counts: with none, Flutter's fallback is black, which is not the page's ink.
Color inkAt(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<IconTheme>()?.data.color ?? DefaultTextStyle.of(context).style.color ?? const Color(0xFF000000);

/// Paints a drawn icon: [washed] paths filled with a third of [color], then [strokes] in [color], on a box
/// [viewBox] wide scaled to the size it is given. Shared by the kit's icons ([AppIcon]) and the app's own
/// (icons.dart).
class DrawnIconPainter extends CustomPainter {
  const DrawnIconPainter({required this.strokes, required this.washed, required this.color, required this.strokeWidth, this.viewBox = 24, this.evenOdd = false, this.filled = false, this.fills = const [], this.washAlpha, this.cut = const [], this.crisp = false});

  /// SVG paths, as written: those drawn as lines, and those filled with the wash under them.
  final List<String> strokes;
  final List<String> washed;

  /// Shapes filled in the whole ink: a Phosphor icon's outline, which is a filled shape rather than a stroke.
  final List<String> fills;

  /// [fills] with hard edges, none smoothed: an icon made of square pixels, which stay square.
  final bool crisp;

  /// How much of the ink the wash is, when not the app's own third ([iconWash]): Phosphor's duotone is a fifth.
  final double? washAlpha;
  final Color color;
  final double strokeWidth;
  final double viewBox;

  /// A body with a hole in it - a cog's middle, a cassette's reels - is filled even-odd, and the hole stays clear.
  final bool evenOdd;

  /// The Filled style: [washed] filled in the whole ink rather than a third of it, and
  /// [cut], the lines inside the body (a clock's hands, a box's tick), cut out of it.
  final bool filled;
  final List<String> cut;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / viewBox, size.height / viewBox);
    final fill = Paint()
      ..style = PaintingStyle.fill
      ..color = filled ? color : color.withValues(alpha: color.a * (washAlpha ?? iconWash));
    if (cut.isNotEmpty) canvas.saveLayer(Rect.fromLTWH(-viewBox / 6, -viewBox / 6, viewBox * 4 / 3, viewBox * 4 / 3), Paint());
    // Each path from the store of them (svg_path.dart): parsed once for its string, and its even-odd self made once.
    for (final d in washed) {
      canvas.drawPath(svgPath(d, evenOdd: evenOdd), fill);
    }
    if (fills.isNotEmpty) {
      final ink = Paint()
        ..style = PaintingStyle.fill
        ..isAntiAlias = !crisp
        ..color = color;
      for (final d in fills) {
        canvas.drawPath(svgPath(d), ink);
      }
    }
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final d in strokes) {
      canvas.drawPath(svgPath(d), stroke);
    }
    if (cut.isNotEmpty) {
      final out = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..blendMode = BlendMode.dstOut;
      for (final d in cut) {
        canvas.drawPath(svgPath(d), out);
      }
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(DrawnIconPainter old) =>
      old.color != color ||
      old.strokeWidth != strokeWidth ||
      old.viewBox != viewBox ||
      old.evenOdd != evenOdd ||
      old.filled != filled ||
      old.washAlpha != washAlpha ||
      !_same(old.fills, fills) ||
      !_same(old.strokes, strokes) ||
      !_same(old.washed, washed) ||
      !_same(old.cut, cut);

  static bool _same(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
