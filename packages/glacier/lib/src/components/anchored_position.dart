import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

// ---------------------------------------------------------------------------------------------------------------------
// The maths: `compute()` of internal/useAnchoredPosition.ts and `buildPath()` of internal/ArrowGlass.tsx, as plain
// functions of rectangles. Nothing here touches a widget; test/anchored_position_test.dart drives it directly.
// ---------------------------------------------------------------------------------------------------------------------

/// A side of the screen (`PhysicalSide`).
enum PhysicalSide { top, bottom, left, right }

/// A side a panel may be asked for (`Side`): the four physical ones, and the two that follow the writing direction.
/// `inlineEnd` is the right in LTR and the left in RTL, `inlineStart` the opposite.
enum AnchorSide { top, bottom, left, right, inlineStart, inlineEnd }

/// Where along its side a panel sits (`Alignment` in useAnchoredPosition.ts; named apart from Flutter's own).
/// On the top and bottom sides `start` and `end` are logical: start hugs the anchor's inline-start edge, which is its
/// right edge under RTL. On the left and right sides they are the block axis: start is the top.
enum AnchorAlignment { start, center, end }

/// Where a floating panel goes against what it hangs from: the `Placement` union of useAnchoredPosition.ts, which is
/// `popoverPlacements` of @glacier/spec. A bare side is that side, centred.
enum Placement {
  top('top', AnchorSide.top, AnchorAlignment.center),
  topStart('top-start', AnchorSide.top, AnchorAlignment.start),
  topCenter('top-center', AnchorSide.top, AnchorAlignment.center),
  topEnd('top-end', AnchorSide.top, AnchorAlignment.end),
  bottom('bottom', AnchorSide.bottom, AnchorAlignment.center),
  bottomStart('bottom-start', AnchorSide.bottom, AnchorAlignment.start),
  bottomCenter('bottom-center', AnchorSide.bottom, AnchorAlignment.center),
  bottomEnd('bottom-end', AnchorSide.bottom, AnchorAlignment.end),
  left('left', AnchorSide.left, AnchorAlignment.center),
  leftStart('left-start', AnchorSide.left, AnchorAlignment.start),
  leftCenter('left-center', AnchorSide.left, AnchorAlignment.center),
  leftEnd('left-end', AnchorSide.left, AnchorAlignment.end),
  right('right', AnchorSide.right, AnchorAlignment.center),
  rightStart('right-start', AnchorSide.right, AnchorAlignment.start),
  rightCenter('right-center', AnchorSide.right, AnchorAlignment.center),
  rightEnd('right-end', AnchorSide.right, AnchorAlignment.end),
  inlineStart('inline-start', AnchorSide.inlineStart, AnchorAlignment.center),
  inlineStartStart('inline-start-start', AnchorSide.inlineStart, AnchorAlignment.start),
  inlineStartCenter('inline-start-center', AnchorSide.inlineStart, AnchorAlignment.center),
  inlineStartEnd('inline-start-end', AnchorSide.inlineStart, AnchorAlignment.end),
  inlineEnd('inline-end', AnchorSide.inlineEnd, AnchorAlignment.center),
  inlineEndStart('inline-end-start', AnchorSide.inlineEnd, AnchorAlignment.start),
  inlineEndCenter('inline-end-center', AnchorSide.inlineEnd, AnchorAlignment.center),
  inlineEndEnd('inline-end-end', AnchorSide.inlineEnd, AnchorAlignment.end);

  const Placement(this.css, this.side, this.align);

  /// The name the web kit writes: `bottom-start`.
  final String css;
  final AnchorSide side;
  final AnchorAlignment align;

  /// The placement the web kit calls [css]. A name it does not know is `bottom-start`, as `parse()` has it.
  static Placement parse(String css) {
    for (final value in values) {
      if (value.css == css) return value;
    }
    return Placement.bottomStart;
  }

  /// A physical side and an alignment as a placement, written as `compute()` reports one: centred is the bare side.
  static Placement of(PhysicalSide side, AnchorAlignment align) {
    switch (side) {
      case PhysicalSide.top:
        return const [Placement.topStart, Placement.top, Placement.topEnd][align.index];
      case PhysicalSide.bottom:
        return const [Placement.bottomStart, Placement.bottom, Placement.bottomEnd][align.index];
      case PhysicalSide.left:
        return const [Placement.leftStart, Placement.left, Placement.leftEnd][align.index];
      case PhysicalSide.right:
        return const [Placement.rightStart, Placement.right, Placement.rightEnd][align.index];
    }
  }

  /// The side of the screen this is on in [direction], before any flip.
  PhysicalSide physicalSide(TextDirection direction) {
    final rtl = direction == TextDirection.rtl;
    switch (side) {
      case AnchorSide.top:
        return PhysicalSide.top;
      case AnchorSide.bottom:
        return PhysicalSide.bottom;
      case AnchorSide.left:
        return PhysicalSide.left;
      case AnchorSide.right:
        return PhysicalSide.right;
      case AnchorSide.inlineStart:
        return rtl ? PhysicalSide.right : PhysicalSide.left;
      case AnchorSide.inlineEnd:
        return rtl ? PhysicalSide.left : PhysicalSide.right;
    }
  }
}

/// `Math.round`: halves go up, where Dart's `round` sends them away from zero.
double jsRound(double value) => (value + 0.5).floorToDouble();

/// What `compute()` returns: where the panel's corner goes, the side it ended on, and where the arrow points.
@immutable
class AnchoredPosition {
  const AnchoredPosition({required this.left, required this.top, required this.side, required this.placement, required this.arrowOffset});

  /// `style.left` and `style.top`: whole pixels, in the space the anchor's rectangle and the viewport were given in.
  final double left;
  final double top;

  /// The side the panel is on, after the logical sides were resolved and after any flip.
  final PhysicalSide side;

  /// [side] with the alignment asked for: what `data-placement` and the arrow read.
  final Placement placement;

  /// The anchor's centre along the panel edge the arrow sits on, measured from the panel's own corner.
  final double arrowOffset;

  Offset get offset => Offset(left, top);

  bool get vertical => side == PhysicalSide.top || side == PhysicalSide.bottom;

  /// `transform-origin`: the middle of the edge that faces the anchor, so the panel grows out of it.
  Alignment get transformOrigin {
    switch (side) {
      case PhysicalSide.bottom:
        return Alignment.topCenter;
      case PhysicalSide.top:
        return Alignment.bottomCenter;
      case PhysicalSide.right:
        return Alignment.centerLeft;
      case PhysicalSide.left:
        return Alignment.centerRight;
    }
  }

  /// The same position with the arrow's place measured afresh ([projectArrowOffset]).
  AnchoredPosition withArrowOffset(double value) => AnchoredPosition(left: left, top: top, side: side, placement: placement, arrowOffset: value);

  @override
  bool operator ==(Object other) =>
      other is AnchoredPosition && other.left == left && other.top == top && other.side == side && other.placement == placement && other.arrowOffset == arrowOffset;

  @override
  int get hashCode => Object.hash(left, top, side, placement, arrowOffset);

  @override
  String toString() => 'AnchoredPosition(${placement.css} at $left, $top, arrow $arrowOffset)';
}

/// `compute()` of useAnchoredPosition.ts, line for line.
///
/// [trigger] is the anchor's rectangle and [viewport] the window's size (`innerWidth`, `innerHeight`), both in the
/// same space; [floating] is the panel's own size. The panel goes [offset] from the anchor on the side asked for,
/// turns to the opposite side when it would overflow and the opposite side has room, and is kept [padding] inside the
/// viewport along the other axis.
AnchoredPosition computeAnchoredPosition({
  required Rect trigger,
  required Size floating,
  required Size viewport,
  Placement placement = Placement.bottomStart,
  double offset = 8,
  double padding = 8,
  TextDirection direction = TextDirection.ltr,
}) {
  final rtl = direction == TextDirection.rtl;
  final vw = viewport.width;
  final vh = viewport.height;
  final align = placement.align;

  // resolve the logical sides to physical ones for this measurement
  var side = placement.physicalSide(direction);

  // flip the primary side when there is not enough room and the opposite fits
  if (side == PhysicalSide.bottom && trigger.bottom + offset + floating.height > vh - padding) {
    if (trigger.top - offset - floating.height > padding) side = PhysicalSide.top;
  } else if (side == PhysicalSide.top && trigger.top - offset - floating.height < padding) {
    if (trigger.bottom + offset + floating.height < vh - padding) side = PhysicalSide.bottom;
  } else if (side == PhysicalSide.right && trigger.right + offset + floating.width > vw - padding) {
    if (trigger.left - offset - floating.width > padding) side = PhysicalSide.left;
  } else if (side == PhysicalSide.left && trigger.left - offset - floating.width < padding) {
    if (trigger.right + offset + floating.width < vw - padding) side = PhysicalSide.right;
  }

  var top = 0.0;
  var left = 0.0;
  final vertical = side == PhysicalSide.top || side == PhysicalSide.bottom;

  if (side == PhysicalSide.bottom) {
    top = trigger.bottom + offset;
  } else if (side == PhysicalSide.top) {
    top = trigger.top - offset - floating.height;
  } else if (side == PhysicalSide.right) {
    left = trigger.right + offset;
  } else {
    left = trigger.left - offset - floating.width;
  }

  if (vertical) {
    // 'start' and 'end' are logical: start hugs the trigger's inline-start edge, which is the right edge under RTL.
    if (align == AnchorAlignment.center) {
      left = trigger.left + trigger.width / 2 - floating.width / 2;
    } else if ((align == AnchorAlignment.start) != rtl) {
      left = trigger.left;
    } else {
      left = trigger.right - floating.width;
    }
    left = math.max(padding, math.min(left, vw - floating.width - padding));
  } else {
    if (align == AnchorAlignment.start) {
      top = trigger.top;
    } else if (align == AnchorAlignment.end) {
      top = trigger.bottom - floating.height;
    } else {
      top = trigger.top + trigger.height / 2 - floating.height / 2;
    }
    top = math.max(padding, math.min(top, vh - floating.height - padding));
  }

  final arrowOffset = vertical ? trigger.left + trigger.width / 2 - left : trigger.top + trigger.height / 2 - top;

  return AnchoredPosition(
    left: jsRound(left),
    top: jsRound(top),
    side: side,
    // reports the RESOLVED physical side (post logical resolution and flip)
    placement: Placement.of(side, align),
    arrowOffset: arrowOffset,
  );
}

/// The arrow's place as the hook publishes it (`--arrow-tip-at`): the anchor's centre projected against where the
/// panel was actually put, [used], in whole pixels. [used] is the panel's corner; left out, it is where
/// [position] asked for.
double projectArrowOffset(Rect trigger, AnchoredPosition position, {Offset? used}) {
  final at = used ?? position.offset;
  return jsRound(position.vertical ? trigger.left + trigger.width / 2 - at.dx : trigger.top + trigger.height / 2 - at.dy);
}

/// What `buildPath()` of ArrowGlass.tsx returns: the one outline of a panel and the tip that points at its anchor.
class ArrowGlassShape {
  const ArrowGlassShape({required this.box, required this.radius, required this.tipCentre, required this.d, required this.path});

  /// The box the outline is drawn in, placed against the panel's own corner: the panel, and the strip the tip
  /// reaches into on the side that faces the anchor.
  final Rect box;

  /// The corner radius used: the one asked for, kept short of half the panel.
  final double radius;

  /// The tip's centre along the edge it sits on, from the panel's corner.
  final double tipCentre;

  /// The outline as the SVG path the web kit writes, in [box]'s own space.
  final String d;

  /// The same outline for a canvas, in [box]'s own space.
  final Path path;
}

/// `buildPath()` of ArrowGlass.tsx: the rounded rectangle [width] by [height] and its tip, as one outline. The tip
/// sits on the edge opposite the placement's side (a panel placed `top` points down at its anchor). [tipAt] is the
/// anchor's centre along that edge; without it the tip goes by the alignment, [tipInset] from the corner.
///
/// [placement] is a resolved one, as [AnchoredPosition.placement] is: a logical side is read as it stands in LTR.
ArrowGlassShape buildArrowGlassShape({
  required double width,
  required double height,
  required double radius,
  required Placement placement,
  double? tipAt,
  double tip = 6,
  double tipHalf = 7,
  double tipInset = 14,
}) {
  final w = width, h = height;
  final side = placement.physicalSide(TextDirection.ltr);
  final align = placement.align;
  final r = math.max(0.0, math.min(radius, math.min(w, h) / 2 - 1));

  // tip center along the tipped edge
  double tipAtFromAlign(double extent) {
    switch (align) {
      case AnchorAlignment.start:
        return tipInset + tipHalf;
      case AnchorAlignment.end:
        return extent - tipInset - tipHalf;
      case AnchorAlignment.center:
        return extent / 2;
    }
  }

  double clamp(double value, double min, double max) => math.max(min, math.min(value, max));

  final out = _Outline();
  if (side == PhysicalSide.top || side == PhysicalSide.bottom) {
    final tx = tipAt == null ? tipAtFromAlign(w) : clamp(tipAt, r + tipHalf, w - r - tipHalf);
    final box = side == PhysicalSide.top ? Rect.fromLTWH(0, 0, w, h + tip) : Rect.fromLTWH(0, -tip, w, h + tip);
    // panel rect occupies y in [y0, y0+h]; tip dips beyond it
    final y0 = side == PhysicalSide.top ? 0.0 : tip;
    final y1 = y0 + h;
    if (side == PhysicalSide.top) {
      // tip on the BOTTOM edge, pointing down
      out
        ..m(r, y0)
        ..h(w - r)
        ..a(r, w, y0 + r)
        ..v(y1 - r)
        ..a(r, w - r, y1)
        ..h(tx + tipHalf)
        ..l(tx, y1 + tip)
        ..l(tx - tipHalf, y1)
        ..h(r)
        ..a(r, 0, y1 - r)
        ..v(y0 + r)
        ..a(r, r, y0)
        ..z();
    } else {
      // tip on the TOP edge, pointing up
      out
        ..m(r, y0)
        ..h(tx - tipHalf)
        ..l(tx, y0 - tip)
        ..l(tx + tipHalf, y0)
        ..h(w - r)
        ..a(r, w, y0 + r)
        ..v(y1 - r)
        ..a(r, w - r, y1)
        ..h(r)
        ..a(r, 0, y1 - r)
        ..v(y0 + r)
        ..a(r, r, y0)
        ..z();
    }
    return ArrowGlassShape(box: box, radius: r, tipCentre: tx, d: out.d, path: out.path);
  }

  final ty = tipAt == null ? tipAtFromAlign(h) : clamp(tipAt, r + tipHalf, h - r - tipHalf);
  final box = side == PhysicalSide.left ? Rect.fromLTWH(0, 0, w + tip, h) : Rect.fromLTWH(-tip, 0, w + tip, h);
  final x0 = side == PhysicalSide.left ? 0.0 : tip;
  final x1 = x0 + w;
  if (side == PhysicalSide.left) {
    // tip on the RIGHT edge, pointing right
    out
      ..m(x0 + r, 0)
      ..h(x1 - r)
      ..a(r, x1, r)
      ..v(ty - tipHalf)
      ..l(x1 + tip, ty)
      ..l(x1, ty + tipHalf)
      ..v(h - r)
      ..a(r, x1 - r, h)
      ..h(x0 + r)
      ..a(r, x0, h - r)
      ..v(r)
      ..a(r, x0 + r, 0)
      ..z();
  } else {
    // tip on the LEFT edge, pointing left
    out
      ..m(x0 + r, 0)
      ..h(x1 - r)
      ..a(r, x1, r)
      ..v(h - r)
      ..a(r, x1 - r, h)
      ..h(x0 + r)
      ..a(r, x0, h - r)
      ..v(ty + tipHalf)
      ..l(x0 - tip, ty)
      ..l(x0, ty - tipHalf)
      ..v(r)
      ..a(r, x0 + r, 0)
      ..z();
  }
  return ArrowGlassShape(box: box, radius: r, tipCentre: ty, d: out.d, path: out.path);
}

/// An SVG path written and drawn at once, so the string a test reads is the outline the canvas gets.
class _Outline {
  final Path path = Path();
  final StringBuffer _d = StringBuffer();

  /// The pen's place, which SVG's `H` and `V` keep one coordinate of.
  double _x = 0, _y = 0;

  String get d => _d.toString();

  /// A number as a JavaScript template literal prints it: `16`, not `16.0`.
  static String _n(double v) => v == v.truncateToDouble() ? v.toInt().toString() : v.toString();

  void _write(String command) {
    if (_d.isNotEmpty) _d.write(' ');
    _d.write(command);
  }

  // SVG's own commands, by their letters: move, horizontal and vertical lines, a line, and (below) arc and close.
  void m(double x, double y) {
    _write('M ${_n(x)} ${_n(y)}');
    path.moveTo(_x = x, _y = y);
  }

  void h(double x) {
    _write('H ${_n(x)}');
    path.lineTo(_x = x, _y);
  }

  void v(double y) {
    _write('V ${_n(y)}');
    path.lineTo(_x, _y = y);
  }

  void l(double x, double y) {
    _write('L ${_n(x)} ${_n(y)}');
    path.lineTo(_x = x, _y = y);
  }

  /// `A r r 0 0 1 x y`: a quarter turn clockwise. With no radius it is a straight line, as SVG has it.
  void a(double r, double x, double y) {
    _write('A ${_n(r)} ${_n(r)} 0 0 1 ${_n(x)} ${_n(y)}');
    if (r <= 0) {
      path.lineTo(x, y);
    } else {
      path.arcToPoint(Offset(x, y), radius: Radius.circular(r));
    }
    _x = x;
    _y = y;
  }

  void z() {
    _write('Z');
    path.close();
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// The measuring: the hook itself. What it read off the DOM a render object reads off the render tree.
// ---------------------------------------------------------------------------------------------------------------------

/// What a floating panel hangs from: the least an anchor has to be is something that can report a rectangle
/// (`VirtualAnchor` in useAnchoredPosition.ts). A widget anywhere in the tree by its [GlobalKey], the target of a
/// [LayerLink], a fixed rectangle, or a point of no size, which is how a menu is hung from where a mouse right-clicked.
abstract class GlacierAnchor {
  const GlacierAnchor();

  /// A widget already on the page, by a key on it. The panel follows it, a press on it is not a press outside the
  /// panel, and it is what takes focus back when the panel closes.
  const factory GlacierAnchor.key(GlobalKey key) = _KeyAnchor;

  /// The [CompositedTransformTarget] that leads [link].
  const factory GlacierAnchor.link(LayerLink link) = _LinkAnchor;

  /// A rectangle in the window, in logical pixels.
  const factory GlacierAnchor.rect(Rect rect) = _RectAnchor;

  /// A point in the window, in logical pixels: a rectangle of no size there (`pointRect`).
  factory GlacierAnchor.point(Offset point) => _RectAnchor(point & Size.zero);

  /// `getBoundingClientRect()`: the anchor's box in the window, in logical pixels, or null while it has none.
  Rect? rect();

  /// `resolveDirection(anchor)`: the writing direction in effect at the anchor, where it is something that has one.
  TextDirection? direction() => null;

  /// `anchor.contains(event.target)`: whether a press at [position], which hit [path], landed on the anchor.
  bool holds(Iterable<HitTestEntry> path, Offset position) => rect()?.contains(position) ?? false;

  /// `anchor.focus()`: hands the keyboard to the anchor, if anything in it can take it.
  bool focus() => false;
}

/// A fixed rectangle: it has no direction, takes no focus, and holds a press that falls inside it.
class _RectAnchor extends GlacierAnchor {
  const _RectAnchor(this._rect);
  final Rect _rect;

  @override
  Rect? rect() => _rect;

  @override
  bool operator ==(Object other) => other is _RectAnchor && other._rect == _rect;

  @override
  int get hashCode => _rect.hashCode;
}

/// A widget by its key: its render box says where it is, whether a press hit it, and what in it can take focus.
class _KeyAnchor extends GlacierAnchor {
  const _KeyAnchor(this.key);
  final GlobalKey key;

  RenderBox? get _box {
    final object = key.currentContext?.findRenderObject();
    return object is RenderBox && object.attached && object.hasSize ? object : null;
  }

  @override
  Rect? rect() {
    final box = _box;
    return box == null ? null : MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);
  }

  @override
  TextDirection? direction() => key.currentContext?.getInheritedWidgetOfExactType<Directionality>()?.textDirection;

  @override
  bool holds(Iterable<HitTestEntry> path, Offset position) {
    final box = _box;
    return box != null && path.any((entry) => identical(entry.target, box));
  }

  // The first focusable node, in the order the enclosing focus node lists them, that sits inside the keyed widget.
  @override
  bool focus() {
    final context = key.currentContext;
    if (context == null) return false;
    final outer = Focus.maybeOf(context, scopeOk: true, createDependency: false) ?? FocusManager.instance.rootScope;
    for (final node in outer.descendants) {
      final at = node.context;
      if (at == null || node.skipTraversal || !node.canRequestFocus || !_within(at, context)) continue;
      node.requestFocus();
      return true;
    }
    return false;
  }

  /// Whether [inner] is [outer] or somewhere under it in the tree.
  static bool _within(BuildContext inner, BuildContext outer) {
    if (identical(inner, outer)) return true;
    var found = false;
    inner.visitAncestorElements((element) {
      found = identical(element, outer);
      return !found;
    });
    return found;
  }

  @override
  bool operator ==(Object other) => other is _KeyAnchor && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// The leader of a layer link: its place is read off the layer tree, so it is known only once a frame has been
/// composited.
class _LinkAnchor extends GlacierAnchor {
  const _LinkAnchor(this.link);
  final LayerLink link;

  @override
  Rect? rect() {
    final leader = link.leader;
    final size = link.leaderSize;
    if (leader == null || size == null || !leader.attached) return null;
    // The leader's place in the window is the transforms of the layers above it, less the root's, which is the
    // window's pixel ratio: the same room a render box's `localToGlobal` answers in.
    final chain = <Layer>[leader];
    for (var parent = leader.parent; parent != null; parent = parent.parent) {
      chain.add(parent);
    }
    final transform = Matrix4.identity();
    for (var i = chain.length - 2; i > 0; i--) {
      (chain[i] as ContainerLayer).applyTransform(chain[i - 1], transform);
    }
    leader.applyTransform(null, transform);
    return MatrixUtils.transformRect(transform, Offset.zero & size);
  }

  @override
  bool operator ==(Object other) => other is _LinkAnchor && other.link == link;

  @override
  int get hashCode => link.hashCode;
}

/// `useAnchoredPosition()` as a widget: lays [child] out at its own size somewhere in the room it is given, which is
/// the whole overlay, and puts it against [anchor] by [computeAnchoredPosition], with the overlay as the viewport.
///
/// Ports internal/useAnchoredPosition.ts. The hook wrote `top` and `left` straight to the node on every scroll and
/// resize; this works the position out as it paints, when every box on the page is where this frame leaves it, and
/// paints again on each frame the app draws while it is up, so the panel tracks its anchor in the same frame and asks
/// for no frames of its own. [onChange] is the hook's `setResult`: it reports, after the frame, when the side the
/// panel ended on or the arrow's place has changed.
///
/// Differs: the viewport is the overlay's box rather than the window, which are the same thing for a root overlay;
/// and there is no reading back of a position a stylesheet overrode (`offsetLeft`), since nothing here can override it.
class GlacierAnchored extends SingleChildRenderObjectWidget {
  const GlacierAnchored({
    super.key,
    required this.anchor,
    this.placement = Placement.bottomStart,
    this.offset = 8,
    this.padding = 8,
    this.matchWidth = false,
    this.direction,
    this.constraints = const BoxConstraints(),
    this.onChange,
    super.child,
  });

  final GlacierAnchor anchor;
  final Placement placement;

  /// Gap between the anchor and the panel, in pixels.
  final double offset;

  /// Viewport inset kept clear when clamping, in pixels.
  final double padding;

  /// Give the panel at least the anchor's width.
  final bool matchWidth;

  /// The writing direction the logical sides resolve in. Left out, it is the anchor's own where it has one, and
  /// otherwise the one in force here.
  final TextDirection? direction;

  /// The panel's own `min-width`, `max-width` and `max-height`. It is laid out as small as these and its content
  /// allow, as a fixed element shrinks to fit.
  final BoxConstraints constraints;

  final ValueChanged<AnchoredPosition>? onChange;

  TextDirection _direction(BuildContext context) => direction ?? anchor.direction() ?? Directionality.of(context);

  @override
  RenderGlacierAnchored createRenderObject(BuildContext context) => RenderGlacierAnchored(
        anchor: anchor,
        placement: placement,
        offset: offset,
        padding: padding,
        matchWidth: matchWidth,
        direction: _direction(context),
        panelConstraints: constraints,
        onChange: onChange,
      );

  @override
  void updateRenderObject(BuildContext context, RenderGlacierAnchored renderObject) {
    renderObject
      ..anchor = anchor
      ..placement = placement
      ..offset = offset
      ..padding = padding
      ..matchWidth = matchWidth
      ..direction = _direction(context)
      ..panelConstraints = constraints
      ..onChange = onChange;
  }
}

/// The box behind [GlacierAnchored]: as big as the overlay, with its one child placed against the anchor as it
/// paints. A press lands on it only where it lands on the child.
class RenderGlacierAnchored extends RenderShiftedBox {
  RenderGlacierAnchored({
    required GlacierAnchor anchor,
    required Placement placement,
    required double offset,
    required double padding,
    required bool matchWidth,
    required TextDirection direction,
    required BoxConstraints panelConstraints,
    this.onChange,
  })  : _anchor = anchor,
        _placement = placement,
        _offset = offset,
        _padding = padding,
        _matchWidth = matchWidth,
        _direction = direction,
        _panelConstraints = panelConstraints,
        super(null);

  ValueChanged<AnchoredPosition>? onChange;

  GlacierAnchor _anchor;
  set anchor(GlacierAnchor value) {
    if (value == _anchor) return;
    _anchor = value;
    _fresh();
  }

  Placement _placement;
  set placement(Placement value) {
    if (value == _placement) return;
    _placement = value;
    _fresh();
  }

  double _offset;
  set offset(double value) {
    if (value == _offset) return;
    _offset = value;
    _fresh();
  }

  double _padding;
  set padding(double value) {
    if (value == _padding) return;
    _padding = value;
    _fresh();
  }

  bool _matchWidth;
  set matchWidth(bool value) {
    if (value == _matchWidth) return;
    _matchWidth = value;
    _fresh();
  }

  TextDirection _direction;
  set direction(TextDirection value) {
    if (value == _direction) return;
    _direction = value;
    markNeedsPaint();
  }

  BoxConstraints _panelConstraints;
  set panelConstraints(BoxConstraints value) {
    if (value == _panelConstraints) return;
    _panelConstraints = value;
    markNeedsLayout();
  }

  /// Where the panel was last put, and against what.
  AnchoredPosition? get position => _position;
  AnchoredPosition? _position;
  Rect? _trigger;

  /// What was last reported through [onChange]; the frame callback that asks for the next paint, while one is
  /// booked; and whether the after-frame look at the anchor is booked.
  Placement? _lastPlacement;
  double? _lastArrow;
  int? _tick;
  bool _checking = false;

  /// What the hook's effect did when one of its dependencies changed: measure again, and report afresh.
  void _fresh() {
    _lastPlacement = null;
    _lastArrow = null;
    markNeedsLayout();
  }

  /// The anchor's rectangle in this box's own space.
  Rect? _anchorRect() {
    final global = _anchor.rect();
    if (global == null) return null;
    return Rect.fromPoints(globalToLocal(global.topLeft), globalToLocal(global.bottomRight));
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) return;
    var inner = _panelConstraints;
    if (_matchWidth) {
      // Another box's size is not this one's to read while it lays out, except from a callback.
      Rect? rect;
      invokeLayoutCallback<BoxConstraints>((_) => rect = _anchor.rect());
      if (rect != null) {
        final width = jsRound(rect!.width);
        inner = inner.copyWith(minWidth: math.max(inner.minWidth, width), maxWidth: math.max(inner.maxWidth, width));
      }
    }
    child.layout(inner, parentUsesSize: true);
  }

  /// `update()`: measure the anchor and the panel, place the panel, and say so if the side or the arrow moved.
  void _place() {
    final child = this.child;
    if (child == null || !child.hasSize) return;
    final rect = _anchorRect() ?? _trigger;
    if (rect == null) return;
    _trigger = rect;
    final next = computeAnchoredPosition(
      trigger: rect,
      floating: child.size,
      viewport: size,
      placement: _placement,
      offset: _offset,
      padding: _padding,
      direction: _direction,
    );
    final data = child.parentData! as BoxParentData;
    if (data.offset != next.offset) {
      data.offset = next.offset;
      markNeedsSemanticsUpdate();
    }
    final arrow = projectArrowOffset(rect, next);
    _position = next.withArrowOffset(arrow);
    if (next.placement != _lastPlacement || arrow != _lastArrow) {
      _lastPlacement = next.placement;
      _lastArrow = arrow;
      final report = _position!;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (attached) onChange?.call(report);
      });
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _place();
    super.paint(context, offset);
    // Again on the next frame the app draws, whenever that is, and never a frame of this one's asking.
    _tick ??= SchedulerBinding.instance.scheduleFrameCallback((_) {
      _tick = null;
      if (attached) markNeedsPaint();
    }, scheduleNewFrame: false);
    // An anchor that only finds its place as the frame is put together (a layer link) may have been read a frame
    // early: look once more when the frame is done, and paint again if it was.
    if (!_checking) {
      _checking = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _checking = false;
        if (!attached) return;
        final now = _anchorRect();
        if (now != null && now != _trigger) markNeedsPaint();
      });
    }
  }

  @override
  void detach() {
    final tick = _tick;
    if (tick != null) SchedulerBinding.instance.cancelFrameCallbackWithId(tick);
    _tick = null;
    super.detach();
  }
}
