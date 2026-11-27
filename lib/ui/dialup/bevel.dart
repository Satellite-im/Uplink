import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../packs/pack_paint.dart';

/// The look Dial-Up's pieces (lib/looks.dart; Matt, 2026-11-16: "base one of them heavily on the old AOL chatrooms"):
/// silver windows with bevelled edges, white wells, square buttons and navy title bars, all drawn from its tokens in
/// assets/css/app.css. Square corners and no shadows: the era's depth was two rings of light and dark, never a blur.

/// Whether the page is drawn as Dial-Up's chat room: asked of the tokens (`--app-chrome-style: bevel`, set only in its
/// rules), not of the look's name, so the layout follows the stylesheet and a test can stamp it like any other look.
bool isDialup(BuildContext context) => isBevelChrome(context.tokens);

/// [isDialup] for code that already holds the tokens.
bool isBevelChrome(Tokens t) => t.raw('app-chrome-style')?.trim() == 'bevel';

/// The colours Dial-Up's pieces draw in, read once from [t]. Every one falls back to the page's own paper and ink, so
/// a piece put under another look by mistake still draws, plainly, rather than failing.
class DialupColors {
  DialupColors.of(Tokens t)
      : chrome = t.colorOf('var(--app-chrome, var(--app-paper-2))'),
        onChrome = t.colorOf('var(--app-on-chrome, var(--app-ink))'),
        hi = t.colorOf('var(--app-bevel-hi, var(--app-paper))'),
        lo = t.colorOf('var(--app-bevel-lo, var(--app-paper-2))'),
        shadow = t.colorOf('var(--app-bevel-shadow, var(--app-ink-4))'),
        dark = t.colorOf('var(--app-bevel-dark, var(--app-ink))'),
        titlebar = t.colorOf('var(--app-titlebar, var(--app-ink))'),
        titlebarEnd = t.colorOf('var(--app-titlebar-end, var(--app-titlebar, var(--app-ink)))'),
        titlebarInk = t.colorOf('var(--app-titlebar-ink, var(--app-paper))'),
        titlebarInactive = t.colorOf('var(--app-titlebar-inactive, var(--app-ink-4))'),
        titlebarInactiveInk = t.colorOf('var(--app-titlebar-inactive-ink, var(--app-paper-2))'),
        paper = t.colorOf('var(--app-paper)'),
        ink = t.colorOf('var(--app-ink)'),
        inkSoft = t.colorOf('var(--app-ink-3)'),
        disabled = t.colorOf('var(--app-ink-4)'),
        nameMine = t.colorOf('var(--app-name-mine, var(--app-ink))'),
        nameTheirs = t.colorOf('var(--app-name-theirs, var(--app-ink))'),
        names = [for (var i = 1; i <= 6; i++) t.colorOf('var(--app-name-$i, var(--app-name-theirs, var(--app-ink)))')],
        wordsMine = t.colorOf('var(--app-line-mine, var(--app-ink))'),
        wordsTheirs = t.colorOf('var(--app-line-theirs, var(--app-ink))'),
        close = t.colorOf('var(--app-titlebar-close, var(--app-on-chrome, var(--app-ink)))'),
        desktop = t.colorOf('var(--app-desktop, var(--app-paper-3))'),
        tooltip = t.colorOf('var(--app-tooltip, var(--app-paper))'),
        onTooltip = t.colorOf('var(--app-on-tooltip, var(--app-ink))'),
        highlight = t.colorOf('var(--app-highlight, var(--app-ink))'),
        onHighlight = t.colorOf('var(--app-on-highlight, var(--app-paper))'),
        night = t.isDark;

  /// The window's silver face and the words on it.
  final Color chrome, onChrome;

  /// The bevel's four: the outer light (top-left), the inner light, the inner shadow and the outer dark (bottom-right).
  final Color hi, lo, shadow, dark;

  /// The title bar: its band, the band's far end (only past the words), its words; and the same for a pane not in
  /// focus (decoration only: a focused pane always uses the active three).
  final Color titlebar, titlebarEnd, titlebarInk, titlebarInactive, titlebarInactiveInk;

  /// The white well, its words, readable secondary words (Host lines, times), and words that are off.
  final Color paper, ink, inkSoft, disabled;

  /// Your own screen name, everyone else's, and the six per-person colours of a room of many.
  final Color nameMine, nameTheirs;
  final List<Color> names;

  /// What you said and what anyone else said, after the name: the page's ink in Dial-Up, and a colour each where a
  /// look tells the two apart by their words as well (`--app-line-mine`, `--app-line-theirs`; Runestone, whose game
  /// drew what you say in blue).
  final Color wordsMine, wordsTheirs;

  /// A title bar's X: the window's ink in Dial-Up, a colour of its own where a look has one (`--app-titlebar-close`).
  final Color close;

  /// The desktop behind the windows (wide gutters only), the hover tip and its words, and a chosen row and its words.
  final Color desktop, tooltip, onTooltip, highlight, onHighlight;

  /// A dark chrome (Runestone's; Dial-Up's own dark half, After Hours, until it was taken out), where a disabled
  /// label has no white emboss under it.
  final bool night;

  /// The colour [address] keeps in a room of many: one of [names], picked by the address alone, so a person is the
  /// same colour in every room and on every phone.
  Color nameFor(String address) {
    final key = address.replaceAll(RegExp(r'[^0-9a-zA-Z]'), '');
    final tail = key.length > 10 ? key.substring(key.length - 10) : key;
    var h = 0;
    for (final c in tail.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return names[h % names.length];
  }
}

/// How a [Bevel] stands: out of the page (a window, a button), into it (a text box, the transcript's well), or a
/// button held down.
enum BevelStyle { raised, sunken, pressed }

/// What a [Bevel] is, to a look that draws its chrome from a resource pack's pictures (lib/packs/): a window or a
/// card, which is the pack's box, or something pressed, which is its button. Dial-Up draws the two alike.
enum BevelKind { panel, button }

/// A surface with the era's bevel: [rings] (1 or 2) of light and dark round a [color] face, light from the upper left.
///
/// Each ring is at most one logical pixel, and two device pixels on a sharp phone screen (Matt's Fold is about 2.6),
/// because one logical pixel there is three device pixels and two rings of it read heavy on every field and button
/// (the design's critique, 2026-11-16). Square, no shadow. The child sits inside the rings, then [padding].
class Bevel extends StatelessWidget {
  const Bevel({super.key, this.style = BevelStyle.raised, this.color, this.rings = 2, this.padding = EdgeInsets.zero, this.child, this.kind = BevelKind.panel, this.small = false, this.ground = false});

  final BevelStyle style;

  /// The face; the window's silver when null.
  final Color? color;
  final int rings;
  final EdgeInsetsGeometry padding;
  final Widget? child;

  /// A window or a button, to a look that draws the two from different pictures of a pack's.
  final BevelKind kind;

  /// A well a line or two high (a field): a pack's frame is drawn at half its size round it, so there is room inside.
  final bool small;

  /// The face is the ground of what it is (a well's paper, as [Sunken] gives it), not a colour of the caller's own:
  /// a pack's picture of that ground may be drawn in its place.
  final bool ground;

  /// One ring's width in logical pixels on this screen.
  static double ringOf(BuildContext context) {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    return dpr >= 2.5 ? 2 / dpr : 1;
  }

  /// The space [rings] take on each side, for laying things out against a bevel.
  static double edgeOf(BuildContext context, {int rings = 2}) => ringOf(context) * rings;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = DialupColors.of(t);
    final ring = ringOf(context);
    final sprite = PackBevel.of(t, style: style, kind: kind, small: small, ground: ground || color == null, toggled: color != null);
    return CustomPaint(
      painter: BevelPainter(colors: c, style: style, face: color ?? c.chrome, ring: ring, rings: rings, sprite: sprite),
      child: Padding(
        padding: EdgeInsets.all(sprite == null || sprite.edge < 0 ? ring * rings : sprite.edge),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// How a [Bevel] is drawn from a resource pack's pictures (lib/packs/pack_paint.dart), where the look draws with one
/// and one is read: which picture, how, and how far in what stands on it starts. Null for everything else, and for a
/// piece the pack has no picture of: the bevel's flat rings are drawn, in the pack's colours.
class PackBevel {
  const PackBevel._({required this.image, required this.inset, required this.scale, required this.edge, this.tile, this.least = 20});

  /// The frame, drawn as a nine-patch with corners [inset] of its pixels square, each pixel [scale] across.
  final ui.Image? image;
  final double inset, scale;

  /// A ground laid side by side under the bevel's own rings, where the piece is a well and not a frame.
  final ui.Image? tile;

  /// How far in from each side what stands on it starts.
  final double edge;

  /// The least a side may be for the frame to be drawn: smaller than this the flat rings are.
  final double least;

  static PackBevel? of(Tokens t, {required BevelStyle style, required BevelKind kind, required bool small, required bool ground, required bool toggled}) {
    final pack = packOf(t);
    if (pack == null) return null;
    final scale = packScale(t);
    if (style == BevelStyle.sunken) {
      if (!ground) return null;
      // The chatbox's parchment, frame and all, where the well is one (`.parchment` and `.dialup-well` say so).
      if (t.raw('app-well')?.trim() == 'parchment') {
        final image = pack['chatbox/background'];
        if (image == null) return null;
        final s = small ? scale / 2 : scale;
        return PackBevel._(image: image, tile: pack['chatbox/ground'], inset: pack.parchmentEdge + 3, scale: s, edge: pack.parchmentEdge * s, least: small ? 24 : 48);
      }
      final tile = pack['resizeable_mode/side_panel_background'];
      return tile == null ? null : PackBevel._(image: null, tile: tile, inset: 0, scale: scale, edge: -1);
    }
    if (kind == BevelKind.button) {
      final held = style == BevelStyle.pressed || toggled;
      final image = (held ? pack['chatbox/button_selected'] : null) ?? pack['chatbox/button'];
      return image == null ? null : PackBevel._(image: image, inset: 6, scale: scale, edge: -1, least: 16);
    }
    final frame = pack['button/frame'];
    return frame == null ? null : PackBevel._(image: frame, inset: 6, scale: scale, edge: 2 * scale, least: 28);
  }
}

/// A white well sunk into the window: the transcript, a list, a text box. The page's paper when [color] is null.
class Sunken extends StatelessWidget {
  const Sunken({super.key, this.color, this.rings = 2, this.padding = EdgeInsets.zero, this.child, this.small = false});

  final Color? color;
  final int rings;
  final EdgeInsetsGeometry padding;
  final Widget? child;

  /// A field, a line or two high ([Bevel.small]).
  final bool small;

  @override
  Widget build(BuildContext context) {
    final paper = color ?? context.tokens.color('app-paper');
    return Bevel(style: BevelStyle.sunken, color: paper, rings: rings, padding: padding, small: small, ground: color == null, child: ClipRect(child: child));
  }
}

/// Paints a [Bevel]: the face, then each ring from the outside in, its top and left edges first and its bottom and
/// right edges over them, so the bottom-right colour takes the two corners where they meet, as the era drew them.
class BevelPainter extends CustomPainter {
  const BevelPainter({required this.colors, required this.style, required this.face, required this.ring, this.rings = 2, this.sprite});

  final DialupColors colors;
  final BevelStyle style;
  final Color face;
  final double ring;
  final int rings;

  /// A resource pack's picture of this piece, drawn in place of the face and its rings where there is one and the
  /// piece is large enough for it.
  final PackBevel? sprite;

  /// Each ring's (top-left, bottom-right), from the outside in.
  List<(Color, Color)> get _rings {
    final c = colors;
    final all = switch (style) {
      BevelStyle.raised => [(c.hi, c.dark), (c.lo, c.shadow)],
      BevelStyle.sunken => [(c.shadow, c.hi), (c.dark, c.lo)],
      BevelStyle.pressed => [(c.dark, c.hi), (c.shadow, c.lo)],
    };
    return all.take(rings.clamp(0, 2)).toList();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..isAntiAlias = false;
    final s = sprite;
    if (s != null && s.image != null && size.shortestSide >= s.least) {
      paintNine(canvas, s.image!, Offset.zero & size, inset: s.inset, scale: s.scale);
      // A frame with a ground of its own (the chatbox's parchment): the ground laid side by side inside the frame,
      // over the middle the nine-patch stretched there.
      final inner = (Offset.zero & size).deflate(s.inset * s.scale);
      if (s.tile != null && inner.width > 0 && inner.height > 0) paintTiled(canvas, s.tile!, inner, scale: s.scale);
      return;
    }
    if (s?.tile != null) {
      paintTiled(canvas, s!.tile!, Offset.zero & size, scale: s.scale);
    } else {
      canvas.drawRect(Offset.zero & size, paint..color = face);
    }
    var d = 0.0;
    for (final (light, shade) in _rings) {
      final w = size.width - 2 * d, h = size.height - 2 * d;
      if (w <= 0 || h <= 0) break;
      paint.color = light;
      canvas.drawRect(Rect.fromLTWH(d, d, w - ring, ring), paint);
      canvas.drawRect(Rect.fromLTWH(d, d, ring, h - ring), paint);
      paint.color = shade;
      canvas.drawRect(Rect.fromLTWH(d, d + h - ring, w, ring), paint);
      canvas.drawRect(Rect.fromLTWH(d + w - ring, d, ring, h), paint);
      d += ring;
    }
  }

  @override
  bool shouldRepaint(BevelPainter old) =>
      old.sprite?.image != sprite?.image || old.sprite?.tile != sprite?.tile || old.sprite?.scale != sprite?.scale || old.style != style || old.face != face || old.ring != ring || old.rings != rings || old.colors.hi != colors.hi || old.colors.lo != colors.lo || old.colors.shadow != colors.shadow || old.colors.dark != colors.dark;
}
