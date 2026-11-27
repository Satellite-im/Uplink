import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../tokens/theme.dart';
import 'field_core.dart';

/// A key cap: a port of `Kbd` (packages/react/src/atoms/display/Typography/Kbd.tsx and the `.kbd` and `.glass` rules
/// of Typography.module.css). Monospace at 0.8em of the text around it, on a sunken chip with a hairline border that
/// is 2px along the bottom.
///
/// What differs from the original:
/// - [child] is the `children`; a [Text] inside takes the key cap's style.
/// - `0.8em` is measured from the ambient [DefaultTextStyle], falling back to 1rem, as the page's inherits.
/// - [style] is laid over the kit's own text style. It is null by default and exists for an app's stylesheet:
///   Ghost.md's typefaces.css sets `kbd { font-feature-settings: var(--app-mono-features); letter-spacing: 0 }`.
/// - `skeleton` is not ported (the Skeleton atom is not in this package yet).
class GlacierKbd extends StatelessWidget {
  const GlacierKbd({super.key, this.glass = false, this.style, required this.child});

  /// Renders the frosted glass material instead of a solid surface.
  final bool glass;

  /// Laid over the key cap's text style; null leaves the kit's.
  final TextStyle? style;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = GlacierTheme.of(context);
    final em = inheritedFontSize(context, t) * 0.8;
    final hairline = t.len('glacier-hairline');
    const bottom = 2.0; // border-bottom-width: 2px
    final radius = t.radius('sm');
    final fonts = t.families('glacier-font-mono');
    final text = DefaultTextStyle.of(context).style.merge(
          TextStyle(
            fontFamily: fonts.isEmpty ? null : fonts.first,
            fontFamilyFallback: fonts.length > 1 ? fonts.sublist(1) : null,
            fontSize: em,
            height: 1,
            leadingDistribution: TextLeadingDistribution.even,
            color: t.color(glass ? 'glacier-text' : 'glacier-text-muted'),
            decoration: TextDecoration.none,
          ).merge(style),
        );

    Widget cap = CustomPaint(
      painter: KitBoxPainter(
        radius: radius,
        fill: t.color(glass ? 'glacier-glass-regular' : 'glacier-surface-sunken'),
        border: t.color(glass ? 'glacier-glass-border' : 'glacier-border'),
        borderWidth: hairline,
        borderBottomWidth: bottom,
        highlight: glass ? t.color('glacier-glass-highlight') : null,
        highlightHeight: hairline,
      ),
      child: Padding(
        // padding: 0.25em 0.5em, inside the border
        padding: EdgeInsets.fromLTRB(hairline + em * 0.5, hairline + em * 0.25, hairline + em * 0.5, bottom + em * 0.25),
        // line-height: 1. The page's line box is the font size to the fraction; Flutter's own line is that rounded
        // to a pixel, so the box is held to the fraction and the line centred in it.
        child: DefaultTextStyle(style: text, child: _LineBox(height: em, child: child)),
      ),
    );
    if (glass) {
      cap = Stack(
        children: [
          Positioned.fill(child: GlassBackdrop(blur: t.len('glacier-blur-sm'), saturate: t.len('glacier-glass-saturate'), radius: radius)),
          cap,
        ],
      );
    }
    return cap;
  }
}

/// A line box of an exact height around one line of text, which sits centred in it.
class _LineBox extends SingleChildRenderObjectWidget {
  const _LineBox({required this.height, required super.child});

  final double height;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderLineBox(height);

  @override
  void updateRenderObject(BuildContext context, _RenderLineBox renderObject) => renderObject.height = height;
}

/// [_LineBox]'s render object: as wide as the line, exactly [_height] tall, the line moved to its middle.
class _RenderLineBox extends RenderShiftedBox {
  _RenderLineBox(this._height) : super(null);

  double _height;
  set height(double value) {
    if (value == _height) return;
    _height = value;
    markNeedsLayout();
  }

  @override
  double computeMinIntrinsicHeight(double width) => _height;

  @override
  double computeMaxIntrinsicHeight(double width) => _height;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final inner = child?.getDryLayout(BoxConstraints(maxWidth: constraints.maxWidth)) ?? Size.zero;
    return constraints.constrain(Size(inner.width, _height));
  }

  @override
  void performLayout() {
    final line = child;
    if (line == null) {
      size = constraints.constrain(Size(0, _height));
      return;
    }
    line.layout(BoxConstraints(maxWidth: constraints.maxWidth), parentUsesSize: true);
    size = constraints.constrain(Size(line.size.width, _height));
    (line.parentData! as BoxParentData).offset = Offset(0, (size.height - line.size.height) / 2);
  }
}
