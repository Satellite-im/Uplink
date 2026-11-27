import 'package:flutter/widgets.dart';

import '../tokens/theme.dart';
import '../tokens/tokens.dart';
import 'css_effects.dart';
import 'pressable.dart';

/// `tone` of a [GlacierPill]: the kit's six colour families.
enum GlacierPillTone { neutral, accent, success, warning, danger, info }

/// `variant` of a [GlacierPill]: the fill treatment.
enum GlacierPillVariant { soft, solid, outline }

/// `size` of a [GlacierPill]: 1.375rem or 1.75rem tall.
enum GlacierPillSize { sm, md }

/// Port of `@glacier/react`'s `Pill` (`atoms/display/Pill/Pill.tsx`, with `Pill.module.css`): a small capsule label
/// in a tone and a fill, with an optional leading [icon] and, given [onRemove], a trailing remove button that makes
/// it a removable tag.
///
/// It is as wide as what it holds and as tall as its size says, border included (the app sizes every box by its
/// border, which is what the kit's own skeleton geometry assumes).
///
/// What differs from the React original:
/// - `shape` (the kit's clipped and slanted plates) and `skeleton` are not ported: this is the plain capsule.
/// - The remove button's name is [dismissLabel], English by default; the kit's locale provider is not ported.
/// - [glass] is ported as the stylesheet's cascade applies it, which is less than its comment says: every tone and
///   variant rule is two classes to `.glass`'s one, so a glass pill keeps its tone's text colour, and a soft or solid
///   one keeps its fill as well. Glass adds the glass border to a soft or solid pill, the glass fill to an outline
///   one, and the blur and the inset highlight to all three.
class GlacierPill extends StatelessWidget {
  const GlacierPill({
    super.key,
    this.tone = GlacierPillTone.neutral,
    this.variant = GlacierPillVariant.soft,
    this.size = GlacierPillSize.md,
    this.icon,
    this.onRemove,
    this.glass = false,
    this.dismissLabel = 'Dismiss',
    this.child,
  });

  final GlacierPillTone tone;
  final GlacierPillVariant variant;
  final GlacierPillSize size;

  /// Leading glyph, hidden from assistive tech. An [Icon] takes the pill's colour and 1.05 of its text size.
  final Widget? icon;

  /// When set, renders a trailing remove button that calls this on a press, turning the pill into a removable tag.
  final VoidCallback? onRemove;

  /// Renders the frosted glass material; see the class comment for what that comes to.
  final bool glass;

  /// The remove button's accessible name (`kitMessages.dismiss`).
  final String dismissLabel;
  final Widget? child;

  /// A `<button>` does not inherit its parent's font size, and `.remove` sets none: its `1.05em` is of the browser's
  /// own 13.3333px for a button, at either pill size.
  static const double _buttonFontSize = 13.3333;

  ({Color? fill, Color border, Color text}) _paint(Tokens t) {
    final name = tone.name;
    final neutral = tone == GlacierPillTone.neutral;
    final quiet = t.color(neutral ? 'glacier-text-muted' : 'glacier-$name-text');
    final none = t.colorOf('transparent');
    final glassBorder = glass ? t.color('glacier-glass-border') : none;
    switch (variant) {
      case GlacierPillVariant.soft:
        return (fill: t.color(neutral ? 'glacier-hover' : 'glacier-$name-soft'), border: glassBorder, text: quiet);
      case GlacierPillVariant.solid:
        // The neutral and accent solids share the accent's contrast colour.
        final contrast = neutral || tone == GlacierPillTone.accent ? 'glacier-accent-contrast' : 'glacier-$name-contrast';
        return (fill: t.color(neutral ? 'glacier-gray-9' : 'glacier-$name-solid'), border: glassBorder, text: t.color(contrast));
      case GlacierPillVariant.outline:
        return (
          fill: glass ? t.color('glacier-glass-regular') : null,
          border: t.color(neutral ? 'glacier-border-strong' : 'glacier-$name-border'),
          text: quiet,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = GlacierTheme.of(context);
    final small = size == GlacierPillSize.sm;
    final paint = _paint(t);
    final hairline = t.len('glacier-hairline');
    final full = t.radius('full');
    final inline = t.space(small ? 2 : 3);
    final gap = t.space(1);
    // `margin-inline: calc(var(--glacier-space-1) * -0.5)` on the icon's start and the remove button's end.
    final tuck = t.lenOf('calc(var(--glacier-space-1) * -0.5)');
    final style = t.text(small ? 'xs' : 'sm', weight: 'medium', color: paint.text).copyWith(height: 1);

    final items = <Widget>[
      if (icon != null)
        ExcludeSemantics(
          child: IconTheme.merge(
            data: IconThemeData(color: paint.text, size: t.lenOf('1.05em', em: style.fontSize)),
            child: icon!,
          ),
        ),
      // `white-space: nowrap`: one line, which a row too narrow for it cuts short rather than breaks.
      if (child != null) Flexible(child: child!),
      if (onRemove != null) _remove(t, paint.text),
    ];

    final Widget pill = SizedBox(
      height: t.lenOf(small ? '1.375rem' : '1.75rem'),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: paint.fill,
          border: Border.all(color: paint.border, width: hairline),
          borderRadius: BorderRadius.circular(full),
        ),
        child: Padding(
          padding: EdgeInsets.all(hairline),
          child: GlacierInsetShadows(
            shadows: glass ? cssShadowsOf(t, 'inset 0 var(--glacier-hairline) 0 var(--glacier-glass-highlight)') : const [],
            radius: full,
            child: Padding(
              padding: EdgeInsetsDirectional.only(
                start: inline + (icon != null ? tuck : 0),
                end: inline + (onRemove != null ? tuck : 0),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < items.length; i++) ...[
                    if (i > 0) SizedBox(width: gap),
                    items[i],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );

    return DefaultTextStyle(
      style: style,
      softWrap: false,
      child: GlacierBackdrop(radius: full, enabled: glass, child: pill),
    );
  }

  /// `.remove`: a round hit target in the pill's own colour that fills to a wash of it on hover.
  Widget _remove(Tokens t, Color color) {
    final side = t.lenOf('1.05em', em: _buttonFontSize);
    final fast = t.duration('glacier-duration-fast');
    final easeOut = t.curve('glacier-ease-out');
    final wash = t.colorOf('color-mix(in oklch, currentColor 18%, transparent)', current: color);
    // One node for the button: the pressable's own semantics come out as two.
    return MergeSemantics(
      child: GlacierPressable(
        onPressed: onRemove,
        semanticLabel: dismissLabel,
        builder: (context, state) => GlacierFocusRing(
          visible: state.focused,
          offset: 1,
          child: AnimatedOpacity(
            opacity: state.hovered || state.focused ? 1 : 0.65,
            duration: fast,
            curve: easeOut,
            child: AnimatedContainer(
              duration: fast,
              curve: easeOut,
              width: side,
              height: side,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: state.hovered ? wash : wash.withValues(alpha: 0),
                borderRadius: BorderRadius.circular(t.radius('full')),
              ),
              child: CustomPaint(size: const Size.square(10), painter: _CrossPainter(color)),
            ),
          ),
        ),
      ),
    );
  }
}

/// The remove glyph: `M2 2l6 6M8 2l-6 6` on a 10 x 10 box, a 1.5 stroke with round ends, in the pill's colour.
class _CrossPainter extends CustomPainter {
  _CrossPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(2, 2), const Offset(8, 8), stroke);
    canvas.drawLine(const Offset(8, 2), const Offset(2, 8), stroke);
  }

  @override
  bool shouldRepaint(_CrossPainter old) => old.color != color;
}
