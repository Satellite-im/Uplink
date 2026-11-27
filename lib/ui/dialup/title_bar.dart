import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../kit/settings_type.dart';
import '../../packs/pack_paint.dart';
import 'bevel.dart';
import 'parts.dart' show DialupBand;

/// Dial-Up's title bar: a navy band with the window's name in bold white at the left and, where there is somewhere to
/// go back to, one small raised X at the right (labelled Back for a screen reader). An optional second line under the
/// name says where you are and who is there: "Telegram · People Here: 4".
///
/// Only the one X, never the era's minimise and maximise: on a phone they would be dead or confusing targets (the
/// design's critique, 2026-11-16). The X is a visual alias for going back; the system's back gesture still works.
/// The band holds navy under the words and brightens toward its far end only under the buttons, because white on the
/// bright end is about 4:1. 40 high on a phone (44 with the X, its press target) and 28 on the computer, plus the
/// second line. It draws no status-bar padding: put it under the inset.
class TitleBar extends StatelessWidget {
  const TitleBar({super.key, required this.title, this.subtitle, this.onClose, this.closeLabel = 'Back', this.active = true, this.leading, this.actions = const [], this.gradient = true, this.titleChild});

  final String title;

  /// Drawn in the words' place where a page has a header of its own (a conversation's face, name and line under it):
  /// it stands in [DialupBand], so whatever it writes in the page's ink is white on the band.
  final Widget? titleChild;

  /// The second line ("network · People Here: N"), in the same white, smaller.
  final String? subtitle;

  /// The X; none is drawn when null.
  final VoidCallback? onClose;

  /// What a screen reader says for the X.
  final String closeLabel;

  /// False for a pane not in focus on the computer: grey band, silver words. Decoration only.
  final bool active;

  /// A small picture before the name (the window's icon), 16 to 20 across.
  final Widget? leading;

  /// More buttons before the X (a [TitleBarButton], or a page's own icon buttons, which stand in [DialupBand] so they
  /// draw white). Keep it to one or two on a phone.
  final List<Widget> actions;

  /// False for a flat band.
  final bool gradient;

  /// The band's height, without a second line, on [t]'s platform.
  static double heightOf(Tokens t, {bool withClose = false}) {
    if (t.attrs['platform'] == 'desktop') return 28;
    return withClose ? TitleBarButton.target : 40;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = DialupColors.of(t);
    final desk = t.attrs['platform'] == 'desktop';
    final band = active ? c.titlebar : c.titlebarInactive;
    final end = active ? c.titlebarEnd : c.titlebarInactive;
    final ink = active ? c.titlebarInk : c.titlebarInactiveInk;
    final buttons = [...actions.map((a) => a is TitleBarButton ? a : DialupBand(child: a)), if (onClose != null) TitleBarButton(glyph: TitleGlyph.close, label: closeLabel, onPressed: onClose)];
    final words = titleChild != null ? DialupBand(child: titleChild!) : Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, desk ? 14 : 16, weight: 'bold', color: ink)),
        ),
        if (subtitle != null) Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, desk ? 12 : 14, color: ink)),
      ],
    );
    return LayoutBuilder(builder: (context, box) {
      // Where the buttons start: the band stays navy up to there, so the words are always on navy.
      final buttonsWidth = buttons.length * (desk ? TitleBarButton.deskTarget : TitleBarButton.target);
      final hold = box.maxWidth.isFinite && box.maxWidth > 0 ? ((box.maxWidth - buttonsWidth - 8) / box.maxWidth).clamp(0.0, 1.0) : 1.0;
      final paint = gradient && buttons.isNotEmpty && end != band
          ? BoxDecoration(gradient: LinearGradient(colors: [band, band, end], stops: [0, hold, 1]))
          : BoxDecoration(color: band);
      // A pack's strip of stone under the band's colour, where the look draws with one (lib/packs/).
      final strip = packOf(t)?['chatbox/buttons_background_stones'];
      return CustomPaint(
        painter: strip == null ? null : _StripPainter(strip),
        child: DecoratedBox(
        decoration: strip == null ? paint : const BoxDecoration(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: heightOf(t, withClose: buttons.isNotEmpty)),
          child: Padding(
            padding: EdgeInsetsDirectional.only(start: desk ? 4 : 8, top: subtitle == null ? 0 : 4, bottom: subtitle == null ? 0 : 4),
            child: Row(
              children: [
                if (leading != null) ...[leading!, SizedBox(width: desk ? 4 : 6)],
                Expanded(child: words),
                ...buttons,
                if (buttons.isNotEmpty) SizedBox(width: desk ? 2 : 0),
              ],
            ),
          ),
        ),
        ),
      );
    });
  }
}

/// A pack's strip of stone as a title bar's band: as high as the band, its pixels square, laid end to end.
class _StripPainter extends CustomPainter {
  const _StripPainter(this.strip);
  final ui.Image strip;

  @override
  void paint(Canvas canvas, Size size) => paintTiled(canvas, strip, Offset.zero & size, scale: size.height / strip.height);

  @override
  bool shouldRepaint(_StripPainter old) => old.strip != strip;
}

/// The glyphs a [TitleBarButton] draws, as paths: the era's bitmaps are not copied, and paths stay sharp at 3x.
enum TitleGlyph { close, help }

/// A title bar's small raised square button, drawn 22 across on a phone (16 on the computer) inside a 44 press target.
class TitleBarButton extends StatelessWidget {
  const TitleBarButton({super.key, required this.glyph, required this.label, required this.onPressed});

  final TitleGlyph glyph;

  /// What a screen reader says: 'Back', 'Details'.
  final String label;
  final VoidCallback? onPressed;

  static const double target = 44, deskTarget = 24;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = DialupColors.of(t);
    final desk = t.attrs['platform'] == 'desktop';
    final face = desk ? 16.0 : 22.0;
    // A pack's own close button, where the look draws with one: the picture whole, lit while held or under the pointer.
    final pack = glyph == TitleGlyph.close ? packOf(t) : null;
    final closed = pack?['other/window_close_button'];
    return GlacierPressable(
      onPressed: onPressed,
      semanticLabel: label,
      builder: (context, state) {
        final held = state.pressed && onPressed != null;
        if (closed != null) {
          final lit = (held || state.hovered ? pack!['other/window_close_button_hovered'] : null) ?? closed;
          return SizedBox(
            width: desk ? deskTarget : target,
            height: desk ? deskTarget : target,
            child: Opacity(opacity: onPressed == null ? 0.4 : 1, child: CustomPaint(painter: _WholePainter(lit, desk ? 20 : 30))),
          );
        }
        return SizedBox(
          width: desk ? deskTarget : target,
          height: desk ? deskTarget : target,
          child: Center(
            child: SizedBox(
              width: face + (desk ? 2 : 4),
              height: face,
              child: Bevel(
                style: held ? BevelStyle.pressed : BevelStyle.raised,
                child: Transform.translate(
                  offset: held ? const Offset(1, 1) : Offset.zero,
                  child: CustomPaint(painter: _GlyphPainter(glyph, onPressed == null ? c.disabled : (glyph == TitleGlyph.close ? c.close : c.onChrome))),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A pack's picture whole at the middle of its box, at most [most] logical pixels high, its pixels square.
class _WholePainter extends CustomPainter {
  const _WholePainter(this.image, this.most);
  final ui.Image image;
  final double most;

  @override
  void paint(Canvas canvas, Size size) {
    final h = most.clamp(0, size.height).toDouble(), w = (size.width).toDouble();
    paintWhole(canvas, image, Rect.fromLTWH(0, (size.height - h) / 2, w, h));
  }

  @override
  bool shouldRepaint(_WholePainter old) => old.image != image || old.most != most;
}

/// Draws one [TitleGlyph] in [ink] at the middle of its box: an X for close, a question mark and its dot for help.
class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.glyph, this.ink);
  final TitleGlyph glyph;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final pen = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = (s * 0.16).clamp(1.5, 3.0)
      ..strokeCap = StrokeCap.square;
    final m = Offset(size.width / 2, size.height / 2);
    final r = s * 0.24;
    switch (glyph) {
      case TitleGlyph.close:
        canvas.drawLine(m + Offset(-r, -r), m + Offset(r, r), pen);
        canvas.drawLine(m + Offset(r, -r), m + Offset(-r, r), pen);
      case TitleGlyph.help:
        final path = Path()
          ..moveTo(m.dx - r * 0.8, m.dy - r * 0.5)
          ..quadraticBezierTo(m.dx - r * 0.8, m.dy - r * 1.3, m.dx, m.dy - r * 1.3)
          ..quadraticBezierTo(m.dx + r * 0.9, m.dy - r * 1.3, m.dx + r * 0.9, m.dy - r * 0.5)
          ..quadraticBezierTo(m.dx + r * 0.9, m.dy, m.dx, m.dy + r * 0.2)
          ..lineTo(m.dx, m.dy + r * 0.6);
        canvas.drawPath(path, pen..strokeCap = StrokeCap.butt);
        canvas.drawRect(Rect.fromCenter(center: Offset(m.dx, m.dy + r * 1.2), width: pen.strokeWidth, height: pen.strokeWidth), Paint()..color = ink);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.glyph != glyph || old.ink != ink;
}
