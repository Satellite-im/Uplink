import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../tokens/css_value.dart';
import '../tokens/theme.dart';
import '../tokens/tokens.dart';
import 'anchored_position.dart';
import 'popover.dart';
import 'pressable.dart';
import '../plain.dart';

// ---------------------------------------------------------------------------------------------------------------------
// Styles: what an app's stylesheet did to the menu through `className`.
// ---------------------------------------------------------------------------------------------------------------------

/// A row's look where it leaves the kit's: what a stylesheet said about `.item` through `className`, or about every
/// row of a panel through the panel's. Each field left null is the kit's own rule.
@immutable
class GlacierMenuItemStyle {
  const GlacierMenuItemStyle({this.minHeight, this.textStyle, this.iconSize, this.color, this.iconColor, this.hoverColor});

  /// `min-block-size` of the row, padding included. The kit sets none.
  final double? minHeight;

  /// Laid over the row's type, which is `--glacier-font-size-sm` at `--glacier-leading-sm` in the page's weight.
  final TextStyle? textStyle;

  /// The size an icon in the row takes if it names none. The kit leaves it to the icon; 16, which every one of its
  /// own menus passes, stands in for that here.
  final double? iconSize;

  /// The row's ink: `--glacier-text`, or `--glacier-danger-text` for a danger row.
  final Color? color;

  /// The leading icon's ink: `--glacier-text-muted`, or `--glacier-danger-text` for a danger row.
  final Color? iconColor;

  /// The wash under a hovered, focused or open row: `--glacier-hover`, or `--glacier-danger-soft` for a danger row.
  final Color? hoverColor;

  /// This style with [over] laid on it: each field [over] sets wins, and the text styles are merged.
  GlacierMenuItemStyle merge(GlacierMenuItemStyle? over) {
    if (over == null) return this;
    return GlacierMenuItemStyle(
      minHeight: over.minHeight ?? minHeight,
      textStyle: textStyle == null ? over.textStyle : textStyle!.merge(over.textStyle),
      iconSize: over.iconSize ?? iconSize,
      color: over.color ?? color,
      iconColor: over.iconColor ?? iconColor,
      hoverColor: over.hoverColor ?? hoverColor,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GlacierMenuItemStyle &&
      other.minHeight == minHeight &&
      other.textStyle == textStyle &&
      other.iconSize == iconSize &&
      other.color == color &&
      other.iconColor == iconColor &&
      other.hoverColor == hoverColor;

  @override
  int get hashCode => Object.hash(minHeight, textStyle, iconSize, color, iconColor, hoverColor);
}

/// A panel's look where it leaves the kit's: what a stylesheet said about `.menu` through `className` (or a flyout's
/// `menuClassName`). Each field left null is the kit's own rule.
@immutable
class GlacierMenuStyle {
  const GlacierMenuStyle({this.minWidth, this.maxWidth, this.maxHeight, this.item});

  /// `.menu { min-width: 12rem }`.
  final double? minWidth;

  /// `.menu { max-width: min(22rem, calc(100vw - 2rem)) }`.
  final double? maxWidth;

  /// `max-block-size` with `overflow-y: auto`: the panel grows no taller, and its rows scroll inside it. The kit sets
  /// none, and a panel taller than the window runs off it.
  final double? maxHeight;

  /// For every row of the panel; a row's own style is laid over it.
  final GlacierMenuItemStyle? item;

  @override
  bool operator ==(Object other) =>
      other is GlacierMenuStyle && other.minWidth == minWidth && other.maxWidth == maxWidth && other.maxHeight == maxHeight && other.item == item;

  @override
  int get hashCode => Object.hash(minWidth, maxWidth, maxHeight, item);
}

/// `.menu { min-width; max-width }` and whatever [style] says instead. `min-width` has the last word, as in CSS.
BoxConstraints _menuConstraints(Tokens t, GlacierMenuStyle? style) {
  final minWidth = style?.minWidth ?? t.lenOf('12rem');
  final maxWidth = style?.maxWidth ?? t.lenOf('min(22rem, calc(100vw - 2rem))');
  return BoxConstraints(minWidth: minWidth, maxWidth: math.max(minWidth, maxWidth), maxHeight: style?.maxHeight ?? double.infinity);
}

// ---------------------------------------------------------------------------------------------------------------------
// Shared panel internals
// ---------------------------------------------------------------------------------------------------------------------

/// `MenuContext`: what a row needs of the menu it is in.
class _MenuScope extends InheritedWidget {
  const _MenuScope({required this.close, required this.open, required this.stack, required this.sub, required super.child});

  /// Closes the whole menu stack and restores focus to where it came from.
  final VoidCallback close;

  /// Whether the nearest ancestor panel is open; a flyout closes when it drops.
  final bool open;

  /// Every panel of the menu, flyouts too.
  final GlacierLayerStack stack;

  /// The flyout this panel is, or null for the menu's own.
  final _GlacierMenuSubState? sub;

  static _MenuScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_MenuScope>();

  @override
  bool updateShouldNotify(_MenuScope old) => old.open != open || !identical(old.stack, stack) || !identical(old.sub, sub);
}

/// The panel a row is in: where it signs up to be roved over, and the style the panel hands every row.
class _PanelScope extends InheritedWidget {
  const _PanelScope({required this.panel, required this.style, required super.child});
  final _MenuPanelState panel;
  final GlacierMenuItemStyle? style;

  static _PanelScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_PanelScope>();

  @override
  bool updateShouldNotify(_PanelScope old) => !identical(old.panel, panel) || old.style != style;
}

/// What a panel does with a key that reaches it: the menu's own handler, or a flyout's.
typedef _PanelKeys = KeyEventResult Function(KeyEvent event, _MenuPanelState panel);

/// The glass panel shared by Menu and MenuSub flyouts (`MenuPanel` in Menu.tsx, `.menu` in Menu.module.css): a
/// `role="menu"` column of rows, a pixel apart, that knows which of its rows can take focus and in what order.
class _MenuPanel extends StatefulWidget {
  const _MenuPanel({
    super.key,
    this.identifier,
    required this.label,
    required this.style,
    required this.focusOnMount,
    required this.onKey,
    this.onEnter,
    this.onExit,
    required this.children,
  });

  /// The panel's `id`, which what opened it names in `aria-controls`.
  final String? identifier;
  final String? label;
  final GlacierMenuStyle? style;

  /// Focus the first item once the panel is in the tree and positioned.
  final bool focusOnMount;
  final _PanelKeys onKey;
  final VoidCallback? onEnter;
  final VoidCallback? onExit;
  final List<Widget> children;

  @override
  State<_MenuPanel> createState() => _MenuPanelState();
}

class _MenuPanelState extends State<_MenuPanel> {
  /// The panel's own focus, where its keys are heard and where focus rests when no row can take it.
  final FocusNode _node = FocusNode(debugLabel: 'GlacierMenu panel', skipTraversal: true);
  final ScrollController _scroll = ScrollController();

  /// The rows in this panel, each signed up by itself as it mounts ([_MenuRowState.didChangeDependencies]).
  final Set<_MenuRowState> _rows = {};

  @override
  void initState() {
    super.initState();
    if (widget.focusOnMount) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) focusItem(0);
      });
    }
  }

  @override
  void dispose() {
    _node.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// `enabledItemsIn(panel)`: this panel's own rows that are not disabled, top to bottom. A flyout's rows are its
  /// own panel's.
  List<_MenuRowState> get _enabled {
    final rows = [
      for (final row in _rows)
        if (row.mounted && !row.widget.disabled) row,
    ];
    rows.sort((a, b) => a._top.compareTo(b._top));
    return rows;
  }

  /// `focusItemIn(panel, index)`, wrapping round the ends.
  void focusItem(int index) {
    final rows = _enabled;
    if (rows.isEmpty) {
      // Every item disabled: focus the panel itself so Escape (handled on the panel) still closes the menu instead
      // of stranding focus.
      _node.requestFocus();
      return;
    }
    final i = ((index % rows.length) + rows.length) % rows.length;
    rows[i].focus();
  }

  /// `navigatePanel`: ArrowUp/ArrowDown/Home/End roving focus shared by every panel. Returns true when handled.
  bool navigate(KeyEvent event) {
    final rows = _enabled;
    final current = rows.indexWhere((row) => row._node.hasPrimaryFocus);
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      focusItem(current + 1);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      focusItem(current - 1);
    } else if (key == LogicalKeyboardKey.home) {
      focusItem(0);
    } else if (key == LogicalKeyboardKey.end) {
      focusItem(rows.length - 1);
    } else {
      return false;
    }
    return true;
  }

  /// A row that took focus is scrolled into view, as `focus()` does on the page, where the panel scrolls at all.
  void _reveal(RenderObject row) {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    position.ensureVisible(row, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
    position.ensureVisible(row, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
  }

  /// A thin bar at the panel's edge under a finger, where the platform's behaviour draws none (a desktop's draws its
  /// own): shown while the rows run past the panel, so a long menu says it scrolls. New to the port; the page left it
  /// to the browser.
  Widget _touchBar(Widget scroller) => switch (defaultTargetPlatform) {
        TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.fuchsia => RawScrollbar(
            controller: _scroll,
            thumbVisibility: true,
            thickness: 3,
            radius: const Radius.circular(1.5),
            thumbColor: GlacierTheme.of(context).color('glacier-text-subtle').withValues(alpha: 0.5),
            mainAxisMargin: 4,
            crossAxisMargin: 1,
            child: scroller,
          ),
        _ => scroller,
      };

  @override
  Widget build(BuildContext context) {
    final t = GlacierTheme.of(context);
    final style = widget.style;
    // `display: flex; flex-direction: column; gap: 1px`
    Widget rows = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 1, children: widget.children);
    if (style?.maxHeight != null) {
      rows = ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(overscroll: false),
        child: _touchBar(SingleChildScrollView(controller: _scroll, child: rows)),
      );
    }
    Widget panel = _MenuGlass(
      // `padding: var(--glacier-space-1)` inside the hairline border
      child: Padding(padding: EdgeInsets.all(t.space(1) + t.len('glacier-hairline')), child: rows),
    );
    // A fixed element is as wide as its widest row, between its `min-width` and `max-width`.
    panel = IntrinsicWidth(child: DefaultTextStyle(style: glacierPanelTextStyle(context), child: panel));
    // The panel's box takes every press that lands in it, as an element does: its padding, a heading, a divider.
    panel = Listener(behavior: HitTestBehavior.opaque, child: panel);
    if (widget.onEnter != null || widget.onExit != null) {
      panel = MouseRegion(onEnter: (_) => widget.onEnter?.call(), onExit: (_) => widget.onExit?.call(), child: panel);
    }
    return Semantics(
      // The framework will not have a menu with nothing in it.
      role: widget.children.isEmpty ? null : SemanticsRole.menu,
      identifier: widget.identifier,
      label: widget.label,
      container: true,
      explicitChildNodes: true,
      child: FocusTraversalGroup(
        child: Focus(
          focusNode: _node,
          skipTraversal: true,
          // The menu is one node to a screen reader, and its rows are that node's own children.
          includeSemantics: false,
          onKeyEvent: (node, event) => widget.onKey(event, this),
          child: _PanelScope(panel: this, style: style?.item, child: panel),
        ),
      ),
    );
  }
}

/// `.menu`'s surface: `--glacier-glass-thick` over a blurred, saturated backdrop, a hairline border in
/// `--glacier-glass-border`, corners of `--glacier-radius-lg`, and
/// `box-shadow: inset 0 var(--glacier-hairline) 0 var(--glacier-glass-highlight), var(--glacier-shadow-4)`.
class _MenuGlass extends StatelessWidget {
  const _MenuGlass({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = GlacierTheme.of(context);
    final radius = t.radius('lg');
    final shadows = evalShadows(t.resolve('inset 0 var(--glacier-hairline) 0 var(--glacier-glass-highlight), var(--glacier-shadow-4)'), ctx: t.css);
    // The panel is its own glass, so its opacity as it comes and goes is the glass's: the blurred page shows through
    // at that strength from the first frame. An opacity put round the shadow and the glass together would be a
    // layer of its own with nothing behind the glass in it; so the two halves, which do not overlap, fade apart.
    final opacity = GlacierAnchoredLayer.opacityOf(context);
    return CustomPaint(
      painter: _OuterShadowPainter([for (final s in shadows) if (!s.inset) s], radius, opacity),
      child: FadeTransition(
        opacity: opacity,
        // In the tree to a screen reader from the frame it mounts, as an element at `opacity: 0` is.
        alwaysIncludeSemantics: true,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: BackdropFilter(enabled: !glacierPlain, 
            filterConfig: glacierGlassFilter(t),
            child: CustomPaint(
              painter: _SurfacePainter(
                fill: t.color('glacier-glass-thick'),
                border: t.color('glacier-glass-border'),
                hairline: t.len('glacier-hairline'),
                radius: radius,
                insets: [for (final s in shadows) if (s.inset) s],
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Whether two lists of layers paint alike, for a painter deciding whether to repaint.
bool _sameShadows(List<CssShadow> a, List<CssShadow> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].offset != b[i].offset || a[i].blur != b[i].blur || a[i].spread != b[i].spread || a[i].color != b[i].color) return false;
  }
  return true;
}

/// A CSS blur radius is twice the sigma of the Gaussian it asks for.
Paint _shadowPaint(CssShadow shadow, [double opacity = 1]) {
  final paint = Paint()..color = shadow.color.withValues(alpha: shadow.color.a * opacity);
  if (shadow.blur > 0) paint.maskFilter = MaskFilter.blur(BlurStyle.normal, shadow.blur / 2);
  return paint;
}

/// The outer layers of a `box-shadow`, drawn as CSS draws them: only outside the box. A [BoxDecoration] paints its
/// shadow under the box as well, which a see-through surface would show, and which the backdrop blur would take in.
class _OuterShadowPainter extends CustomPainter {
  _OuterShadowPainter(this.shadows, this.radius, this.opacity) : super(repaint: opacity);
  final List<CssShadow> shadows;
  final double radius;
  final Animation<double> opacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (shadows.isEmpty || opacity.value <= 0) return;
    final box = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius));
    var reach = 0.0;
    for (final s in shadows) {
      reach = math.max(reach, s.offset.distance + s.blur * 2 + s.spread.abs());
    }
    canvas.save();
    canvas.clipPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect((Offset.zero & size).inflate(reach + 1))
        ..addRRect(box),
    );
    // The first layer named is the one on top.
    for (final s in shadows.reversed) {
      canvas.drawRRect(box.shift(s.offset).inflate(s.spread), _shadowPaint(s, opacity.value));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OuterShadowPainter old) => old.radius != radius || !identical(old.opacity, opacity) || !_sameShadows(old.shadows, shadows);
}

/// The fill to the border's outer edge, the inset layers of the `box-shadow` inside its inner edge, and the border.
class _SurfacePainter extends CustomPainter {
  _SurfacePainter({required this.fill, required this.border, required this.hairline, required this.radius, required this.insets});
  final Color fill;
  final Color border;
  final double hairline;
  final double radius;
  final List<CssShadow> insets;

  @override
  void paint(Canvas canvas, Size size) {
    final outer = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius));
    final inner = outer.deflate(hairline);
    canvas.drawRRect(outer, Paint()..color = fill);
    for (final s in insets.reversed) {
      // An inset shadow is the shadow of everything but a hole, the padding box moved by the offset and shrunk by
      // the spread, seen inside the padding box.
      final hole = inner.shift(s.offset).deflate(s.spread);
      canvas.save();
      canvas.clipRRect(inner);
      canvas.drawPath(
        Path()
          ..fillType = PathFillType.evenOdd
          ..addRect(inner.outerRect.inflate(s.offset.distance + s.blur * 2 + s.spread.abs() + 1))
          ..addRRect(hole),
        _shadowPaint(s),
      );
      canvas.restore();
    }
    canvas.drawDRRect(outer, inner, Paint()..color = border);
  }

  @override
  bool shouldRepaint(_SurfacePainter old) =>
      old.fill != fill || old.border != border || old.hairline != hairline || old.radius != radius || !_sameShadows(old.insets, insets);
}

// ---------------------------------------------------------------------------------------------------------------------
// Menu
// ---------------------------------------------------------------------------------------------------------------------

/// A dropdown list of actions anchored to a trigger. Built on the same anchored overlay as Popover (it floats over
/// everything on the root overlay, flips and clamps on screen, and closes on outside press or Escape) but with menu
/// semantics: a `role="menu"` panel of `role="menuitem"` rows, arrow-key roving focus, and select-to-close.
///
/// Ports `Menu` of organisms/Menu/Menu.tsx and `.menu` of Menu.module.css. The props are the React's by name:
/// [trigger], [placement], [open] / [defaultOpen] / [onOpenChange] (controlled when [open] is given), [ariaLabel]
/// for `aria-label`, and [children], which are [GlacierMenuItem], [GlacierMenuSub], [GlacierMenuSeparator] and
/// [GlacierMenuLabel] rows.
///
/// Keys, as in the React: Down and Up move between the rows that are not disabled, round the ends; Home and End go
/// to the first and last; Enter and Space choose; Escape closes and puts focus back on the trigger; Tab closes and
/// goes on its way. The first row takes focus as the menu opens, or the panel itself if every row is disabled.
/// There is no typeahead and there are no checked or radio rows, since the React has none.
///
/// Differs from the React:
/// - [trigger] is a builder, handed what the React wrote onto the element it cloned: wire `trigger.toggle` to the
///   press.
/// - [anchor] is new: something already on the page to hang from, a key, a layer link, a rectangle or a point,
///   which is what Ghost.md's PopMenu built a stand-in trigger to get. Focus goes back to it as it would to a trigger.
/// - [style] stands in for `className`, each field defaulting to the kit's own rule.
/// - Android's back gesture closes it.
/// - Left and Right on a row that has no flyout are swallowed, so an app's own arrow-key focus travel does not carry
///   the keyboard out of an open menu; on the page those keys did nothing.
/// - `onOpenChange` is called when the state changes, and not again while it is already closing.
/// - `aria-haspopup` has no counterpart in Flutter's semantics; `aria-expanded` and `aria-controls` are carried.
/// - The panel takes the page's root tokens ([GlacierRootScope]), not those in force at the trigger, as a portalled
///   panel took the body's.
/// - `ContextMenu`, which shares Menu.tsx, is not ported; a menu at a point is `anchor: GlacierAnchor.point(...)`.
class GlacierMenu extends StatefulWidget {
  const GlacierMenu({
    super.key,
    this.trigger,
    this.anchor,
    this.placement = Placement.bottomStart,
    this.open,
    this.defaultOpen = false,
    this.onOpenChange,
    this.ariaLabel,
    this.style,
    required this.children,
  }) : assert(trigger != null || anchor != null, 'A menu hangs from its trigger or from an anchor.');

  /// The element that toggles the menu.
  final GlacierTriggerBuilder? trigger;

  /// What the menu hangs from, where that is not the trigger.
  final GlacierAnchor? anchor;

  /// Where to place the menu relative to the trigger.
  final Placement placement;
  final bool? open;
  final bool defaultOpen;
  final ValueChanged<bool>? onOpenChange;

  /// Accessible label for the menu.
  final String? ariaLabel;

  /// The panel's look where it leaves the kit's (`className`).
  final GlacierMenuStyle? style;

  final List<Widget> children;

  @override
  State<GlacierMenu> createState() => _GlacierMenuState();
}

class _GlacierMenuState extends State<GlacierMenu> {
  final GlobalKey _triggerKey = GlobalKey(debugLabel: 'GlacierMenu trigger');

  /// The menu's panel and every flyout's, so a press in any of them is inside the menu.
  final GlacierLayerStack _stack = GlacierLayerStack();

  /// Whether it is open, where the menu holds that itself (no `open` given).
  late bool _internal = widget.defaultOpen;

  bool get _isOpen => widget.open ?? _internal;
  GlacierAnchor get _anchor => widget.anchor ?? GlacierAnchor.key(_triggerKey);
  String get _menuId => 'glacier-menu-${identityHashCode(this)}';

  /// Opens or closes: the menu's own state where it holds it, and the listener told, only on a real change.
  void _setOpenState(bool next) {
    if (!mounted || next == _isOpen) return;
    if (widget.open == null) setState(() => _internal = next);
    widget.onOpenChange?.call(next);
  }

  /// Closes the menu and puts focus back on what it hangs from: Escape, or a row chosen.
  void _close() {
    _setOpenState(false);
    _anchor.focus();
  }

  /// The root panel's keys, after the roving ones: Escape, Tab, and the side arrows swallowed.
  KeyEventResult _onKey(KeyEvent event, _MenuPanelState panel) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (panel.navigate(event)) return KeyEventResult.handled;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab) {
      _setOpenState(false);
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) return KeyEventResult.handled;
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final t = GlacierTheme.of(context);
    final build = widget.trigger;
    Widget trigger = const SizedBox.shrink();
    if (build != null) {
      trigger = Semantics(
        expanded: _isOpen,
        controlsNodes: _isOpen ? {_menuId} : null,
        child: KeyedSubtree(
          key: _triggerKey,
          child: build(context, GlacierTrigger(isOpen: _isOpen, toggle: () => _setOpenState(!_isOpen), setOpen: _setOpenState)),
        ),
      );
    }
    return GlacierAnchoredLayer(
      open: _isOpen,
      anchor: widget.anchor,
      placement: widget.placement,
      constraints: _menuConstraints(t, widget.style),
      stack: _stack,
      fades: false,
      onPressOutside: () => _setOpenState(false),
      onBack: () => _setOpenState(false),
      panel: (context, position) => _MenuScope(
        close: _close,
        open: _isOpen,
        stack: _stack,
        sub: null,
        child: _MenuPanel(identifier: _menuId, label: widget.ariaLabel, style: widget.style, focusOnMount: true, onKey: _onKey, children: widget.children),
      ),
      child: trigger,
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// MenuSub
// ---------------------------------------------------------------------------------------------------------------------

/// How long the pointer rests on a flyout's row before it opens, how long after leaving before it closes, and the
/// gap in logical pixels between the row's panel and the flyout.
const Duration _subOpenDelay = Duration(milliseconds: 120);
const Duration _subCloseDelay = Duration(milliseconds: 300);
const double _subOffset = 2;

/// A flyout submenu row inside a [GlacierMenu]. Renders like a [GlacierMenuItem] with a trailing chevron; its child
/// panel opens toward inline-end of the row (right in LTR, left in RTL, flipping at the viewport edge) on hover with
/// an intent delay, or on the arrow key pointing into it (ArrowRight in LTR, ArrowLeft in RTL), or Enter, Space or a
/// press, which focus its first row. The opposite arrow closes the flyout and returns focus to the row; Escape
/// closes the whole stack. Nests.
///
/// Ports `MenuSub` of organisms/Menu/Menu.tsx and the `.chevron` and `[aria-expanded]` rules of Menu.module.css.
/// The props are the React's by name: [label], [icon], [disabled], [children], [style] for `className` and
/// [menuStyle] for `menuClassName`, with [ariaLabel] for `aria-label`. The flyout is named by [ariaLabel], or by
/// [label] where that is a [Text].
///
/// Differs from the React:
/// - The hover that opens and closes it is a mouse's. On the page a finger's landing and lifting were pointer
///   arrivals and departures too, so a flyout a finger had touched closed 300ms after the finger lifted.
/// - The arrow key, Enter or a press on a row whose flyout the pointer already opened moves focus into the flyout.
///   In the React nothing happened then, because the state it set had not changed.
class GlacierMenuSub extends StatefulWidget {
  const GlacierMenuSub({
    super.key,
    required this.label,
    this.icon,
    this.disabled = false,
    this.ariaLabel,
    this.style,
    this.menuStyle,
    required this.children,
  });

  /// The row's label.
  final Widget label;

  /// Leading glyph.
  final Widget? icon;

  /// Dims the row and keeps the flyout shut.
  final bool disabled;
  final String? ariaLabel;

  /// The row's look where it leaves the kit's (`className`).
  final GlacierMenuItemStyle? style;

  /// The flyout panel's look where it leaves the kit's (`menuClassName`).
  final GlacierMenuStyle? menuStyle;

  /// The flyout content: [GlacierMenuItem] rows, separators, or deeper [GlacierMenuSub]s.
  final List<Widget> children;

  @override
  State<GlacierMenuSub> createState() => _GlacierMenuSubState();
}

class _GlacierMenuSubState extends State<GlacierMenuSub> {
  final GlobalKey<_MenuRowState> _rowKey = GlobalKey(debugLabel: 'GlacierMenuSub row');
  final GlobalKey<_MenuPanelState> _panelKey = GlobalKey(debugLabel: 'GlacierMenuSub panel');

  /// Used only where the flyout stands outside any menu; inside one it joins the menu's stack.
  final GlacierLayerStack _ownStack = GlacierLayerStack();
  bool _isOpen = false;

  /// The hover's waits: one running while the pointer rests on the row, one after it has left.
  Timer? _openTimer;
  Timer? _closeTimer;

  /// The panel this row is in: the menu's own, or the flyout it flies out of.
  _MenuScope? _scope;

  void _clearOpen() {
    _openTimer?.cancel();
    _openTimer = null;
  }

  void _clearClose() {
    _closeTimer?.cancel();
    _closeTimer = null;
  }

  /// Opens the flyout now. [withFocus] (a key or a press, not a hover) sends focus to its first row.
  void _openSub(bool withFocus) {
    _clearOpen();
    _clearClose();
    if (widget.disabled || !mounted) return;
    setState(() => _isOpen = true);
    if (!withFocus) return;
    // Focus the flyout's first item once the panel is in the tree and positioned.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted && _isOpen) _panelKey.currentState?.focusItem(0);
    });
  }

  void _closeSub() {
    _clearOpen();
    _clearClose();
    if (mounted && _isOpen) setState(() => _isOpen = false);
  }

  /// Closes the flyout after the close delay, unless the pointer comes back first.
  void _scheduleClose() {
    _clearClose();
    _closeTimer = Timer(_subCloseDelay, () {
      _closeTimer = null;
      _closeSub();
    });
  }

  /// The pointer is on this flyout's panel, or on one that flies out of it: every flyout it is inside stays.
  void _panelEntered() {
    for (_GlacierMenuSubState? sub = this; sub != null; sub = sub._scope?.sub) {
      sub._clearClose();
    }
  }

  /// The pointer left this flyout's panel, and with it every flyout the panel is inside. Arriving on one of those
  /// in the same movement takes its close back.
  void _panelLeft() {
    for (_GlacierMenuSubState? sub = this; sub != null; sub = sub._scope?.sub) {
      if (sub._isOpen) sub._scheduleClose();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scope = _MenuScope.maybeOf(context);
    // The flyout animates out with its ancestor instead of lingering at full opacity while the parent panel fades.
    if (!(_scope?.open ?? true)) {
      _clearOpen();
      _clearClose();
      _isOpen = false;
    }
  }

  @override
  void didUpdateWidget(GlacierMenuSub old) {
    super.didUpdateWidget(old);
    if (widget.disabled && _isOpen) {
      _clearOpen();
      _clearClose();
      _isOpen = false;
    }
  }

  @override
  void dispose() {
    _clearOpen();
    _clearClose();
    super.dispose();
  }

  bool get _rtl => Directionality.of(context) == TextDirection.rtl;

  /// Keys on the row itself: the arrow that opens the flyout.
  KeyEventResult _onRowKey(FocusNode node, KeyEvent event) {
    if (widget.disabled || event is KeyUpEvent) return KeyEventResult.ignored;
    // APG: the arrow that points INTO the flyout opens it, so the horizontal arrows invert under RTL.
    final openKey = _rtl ? LogicalKeyboardKey.arrowLeft : LogicalKeyboardKey.arrowRight;
    if (event.logicalKey != openKey) return KeyEventResult.ignored;
    _openSub(true);
    return KeyEventResult.handled;
  }

  /// Keys inside the flyout's panel, after the roving ones: the arrow back to the row, and Escape.
  KeyEventResult _onPanelKey(KeyEvent event, _MenuPanelState panel) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (panel.navigate(event)) return KeyEventResult.handled;
    // the arrow pointing back at the row closes: ArrowLeft in LTR, ArrowRight in RTL
    final closeKey = _rtl ? LogicalKeyboardKey.arrowRight : LogicalKeyboardKey.arrowLeft;
    if (event.logicalKey == closeKey) {
      _closeSub();
      _rowKey.currentState?.focus();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      // close this level and let the event go on up so every ancestor panel closes too - the root then restores
      // focus to its trigger.
      _closeSub();
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final t = GlacierTheme.of(context);
    final scope = _scope;
    final parentOpen = scope?.open ?? true;
    final label = widget.label;
    final stack = scope?.stack ?? _ownStack;
    return GlacierAnchoredLayer(
      open: _isOpen,
      placement: Placement.inlineEndStart,
      offset: _subOffset,
      constraints: _menuConstraints(t, widget.menuStyle),
      stack: stack,
      fades: false,
      panel: (context, position) => _MenuScope(
        close: scope?.close ?? _closeSub,
        open: parentOpen && _isOpen,
        stack: stack,
        sub: this,
        child: _MenuPanel(
          key: _panelKey,
          label: widget.ariaLabel ?? (label is Text ? label.data : null),
          style: widget.menuStyle,
          focusOnMount: false,
          onKey: _onPanelKey,
          onEnter: _panelEntered,
          onExit: _panelLeft,
          children: widget.children,
        ),
      ),
      child: MouseRegion(
        onEnter: (_) {
          if (widget.disabled) return;
          _clearClose();
          if (_isOpen || _openTimer != null) return;
          _openTimer = Timer(_subOpenDelay, () {
            _openTimer = null;
            _openSub(false);
          });
        },
        onExit: (_) {
          _clearOpen();
          if (_isOpen) _scheduleClose();
        },
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          includeSemantics: false,
          onKeyEvent: _onRowKey,
          child: _MenuRow(
            key: _rowKey,
            icon: widget.icon,
            label: label,
            chevron: true,
            disabled: widget.disabled,
            expanded: _isOpen,
            ariaLabel: widget.ariaLabel,
            style: widget.style,
            onPressed: () => _openSub(true),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Items
// ---------------------------------------------------------------------------------------------------------------------

/// A single action row inside a [GlacierMenu].
///
/// Ports `MenuItem` of organisms/Menu/Menu.tsx and `.item`, `.icon`, `.label` and `.shortcut` of Menu.module.css.
/// The props are the React's by name: [icon], [shortcut], [danger], [onSelect], [disabled], [child] for `children`,
/// with [ariaLabel] for `aria-label` and [style] for `className`. It is pressed through [GlacierPressable], as every
/// control of the kit is.
///
/// Differs from the React: a row under a finger shows the hover wash while it is held, which a phone's browser did
/// by leaving `:hover` on whatever was tapped. The other attributes a `<button>` takes are not carried.
class GlacierMenuItem extends StatelessWidget {
  const GlacierMenuItem({
    super.key,
    this.icon,
    this.shortcut,
    this.danger = false,
    this.onSelect,
    this.disabled = false,
    this.ariaLabel,
    this.style,
    this.closes = true,
    required this.child,
  });

  /// Leading glyph.
  final Widget? icon;

  /// Trailing shortcut hint, e.g. "⌘C".
  final Widget? shortcut;

  /// Paints the row in the danger tone.
  final bool danger;

  /// Called when the item is chosen; the menu then closes, unless [closes] is false.
  final VoidCallback? onSelect;

  /// Whether choosing it closes the menu: false for a row that shows more rows in place in the same panel. New to
  /// the port; every row of the React's closed it.
  final bool closes;

  /// Dims the row, takes it out of the arrow keys' round, and makes choosing it do nothing.
  final bool disabled;

  /// The row's whole name, in place of what it shows.
  final String? ariaLabel;

  /// The row's look where it leaves the kit's (`className`).
  final GlacierMenuItemStyle? style;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return _MenuRow(
      icon: icon,
      label: child,
      shortcut: shortcut,
      danger: danger,
      disabled: disabled,
      ariaLabel: ariaLabel,
      style: style,
      onPressed: () {
        onSelect?.call();
        if (closes) context.getInheritedWidgetOfExactType<_MenuScope>()?.close();
      },
    );
  }
}

/// The `<button role="menuitem">` both kinds of row are.
class _MenuRow extends StatefulWidget {
  const _MenuRow({
    super.key,
    required this.icon,
    required this.label,
    this.shortcut,
    this.chevron = false,
    this.danger = false,
    required this.disabled,
    this.expanded,
    required this.ariaLabel,
    required this.style,
    required this.onPressed,
  });

  final Widget? icon;
  final Widget label;
  final Widget? shortcut;
  final bool chevron;
  final bool danger;
  final bool disabled;

  /// `aria-expanded`, on a row that opens a flyout.
  final bool? expanded;
  final String? ariaLabel;
  final GlacierMenuItemStyle? style;
  final VoidCallback onPressed;

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  /// `tabIndex={-1}`: focus comes by the arrow keys, and Tab does not stop here.
  final FocusNode _node = FocusNode(debugLabel: 'GlacierMenu row', skipTraversal: true);

  /// The panel this row has signed up with.
  _MenuPanelState? _panel;

  /// Where the row's top is on the screen, which is what orders a panel's rows; last where it is not laid out.
  double get _top {
    final box = context.findRenderObject();
    return box is RenderBox && box.hasSize ? box.localToGlobal(Offset.zero).dy : double.infinity;
  }

  /// Takes the keyboard's focus and scrolls itself into view in a panel that scrolls.
  void focus() {
    _node.requestFocus();
    final box = context.findRenderObject();
    if (box != null) _panel?._reveal(box);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final panel = _PanelScope.maybeOf(context)?.panel;
    if (identical(panel, _panel)) return;
    _panel?._rows.remove(this);
    _panel = panel;
    panel?._rows.add(this);
  }

  @override
  void dispose() {
    _panel?._rows.remove(this);
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = GlacierTheme.of(context);
    final style = (_PanelScope.maybeOf(context)?.style ?? const GlacierMenuItemStyle()).merge(widget.style);
    final danger = widget.danger;
    final disabled = widget.disabled;
    final named = widget.ariaLabel != null;

    final ink = style.color ?? t.color(danger ? 'glacier-danger-text' : 'glacier-text');
    final iconInk = style.iconColor ?? t.color(danger ? 'glacier-danger-text' : 'glacier-text-muted');
    final wash = style.hoverColor ?? t.color(danger ? 'glacier-danger-soft' : 'glacier-hover');
    final subtle = t.color('glacier-text-subtle');
    // `font: inherit; font-size: var(--glacier-font-size-sm); line-height: var(--glacier-leading-sm)`
    final text = glacierPanelTextStyle(context).merge(t.text('sm', color: ink)).merge(style.textStyle);
    final em = text.fontSize ?? t.fontSize('sm');
    final line = em * (text.height ?? t.len('glacier-leading-sm'));
    final gap = t.space(3);

    // A row with a name of its own is read by that name, and what it shows is kept from the screen reader.
    Widget heard(Widget child) => named ? ExcludeSemantics(child: child) : child;

    final children = <Widget>[
      if (widget.icon != null) ...[
        // `.icon { flex: none; width: 1em; height: 1em }`: an icon larger than that spills evenly out of it.
        SizedBox(
          width: em,
          height: em,
          child: OverflowBox(
            minWidth: 0,
            minHeight: 0,
            maxWidth: double.infinity,
            maxHeight: double.infinity,
            child: IconTheme.merge(
              data: IconThemeData(color: iconInk, size: style.iconSize ?? 16),
              child: DefaultTextStyle(style: text.copyWith(color: iconInk), child: heard(widget.icon!)),
            ),
          ),
        ),
        SizedBox(width: gap),
      ],
      // `.label { flex: 1 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap }`
      Expanded(
        child: DefaultTextStyle(style: text, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, child: heard(widget.label)),
      ),
      if (widget.shortcut != null) ...[
        // `.shortcut { flex: none; margin-inline-start: var(--glacier-space-4) }`, after the row's own gap
        SizedBox(width: gap + t.space(4)),
        DefaultTextStyle(
          style: text.copyWith(
            color: subtle,
            fontSize: t.fontSize('xs'),
            fontFeatures: [...?text.fontFeatures, const FontFeature.tabularFigures()],
          ),
          child: heard(widget.shortcut!),
        ),
      ],
      if (widget.chevron) ...[
        // `.chevron { flex: none; margin-inline-start: var(--glacier-space-2) }`, after the row's own gap
        SizedBox(width: gap + t.space(2)),
        CustomPaint(size: const Size.square(10), painter: _ChevronPainter(subtle, Directionality.of(context) == TextDirection.rtl)),
      ],
    ];

    Widget row = GlacierPressable(
      onPressed: disabled ? null : widget.onPressed,
      focusNode: _node,
      excludeSemantics: true,
      builder: (context, state) {
        // `:hover:not([aria-disabled])`, `:focus-visible` and `[aria-expanded='true']` share one wash.
        final lit = state.hovered || state.focused || state.pressed || widget.expanded == true;
        Widget face = AnimatedContainer(
          // `transition: background-color var(--glacier-duration-fast) var(--glacier-ease-out)`
          duration: t.duration('glacier-duration-fast'),
          curve: t.curve('glacier-ease-out'),
          constraints: BoxConstraints(minHeight: style.minHeight ?? 0),
          padding: EdgeInsets.symmetric(vertical: t.space(2), horizontal: gap),
          decoration: BoxDecoration(
            color: lit ? wash : wash.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(t.radius('md')),
          ),
          // The row is its line's height however the text engine rounds the glyphs' own.
          child: ConstrainedBox(constraints: BoxConstraints(minHeight: line), child: Row(children: children)),
        );
        if (disabled) {
          // `[aria-disabled='true'] { opacity: 0.5; cursor: not-allowed }`
          face = MouseRegion(cursor: SystemMouseCursors.forbidden, child: Opacity(opacity: 0.5, child: face));
        }
        return face;
      },
    );

    return MergeSemantics(
      child: Semantics(
        role: SemanticsRole.menuItem,
        enabled: !disabled,
        label: widget.ariaLabel,
        expanded: widget.expanded,
        onTap: disabled ? null : widget.onPressed,
        child: row,
      ),
    );
  }
}

/// `SubChevron`: `M3.5 1.5 7 5 3.5 8.5` in a ten-pixel box, stroked 1.5 with round ends. It points into the flyout,
/// so it is mirrored under RTL.
class _ChevronPainter extends CustomPainter {
  _ChevronPainter(this.color, this.mirrored);
  final Color color;
  final bool mirrored;

  @override
  void paint(Canvas canvas, Size size) {
    if (mirrored) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    canvas.drawPath(
      Path()
        ..moveTo(3.5, 1.5)
        ..lineTo(7, 5)
        ..lineTo(3.5, 8.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_ChevronPainter old) => old.color != color || old.mirrored != mirrored;
}

/// A divider between groups of items.
///
/// Ports `MenuSeparator` of organisms/Menu/Menu.tsx and `.separator` of Menu.module.css. Flutter's semantics have no
/// separator role, so it says nothing to a screen reader.
class GlacierMenuSeparator extends StatelessWidget {
  const GlacierMenuSeparator({super.key});

  @override
  Widget build(BuildContext context) {
    final t = GlacierTheme.of(context);
    return Padding(
      // `margin: var(--glacier-space-1) var(--glacier-space-2)`
      padding: EdgeInsets.symmetric(vertical: t.space(1), horizontal: t.space(2)),
      child: SizedBox(height: t.len('glacier-hairline'), child: ColoredBox(color: t.color('glacier-border-subtle'))),
    );
  }
}

/// A non-interactive section heading inside a [GlacierMenu].
///
/// Ports `MenuLabel` of organisms/Menu/Menu.tsx and `.groupLabel` of Menu.module.css.
///
/// Differs from the React: `text-transform: uppercase` reaches only a [child] that is a plain [Text], whose words
/// are shown in capitals and read out as written; any other child is shown as it is.
class GlacierMenuLabel extends StatelessWidget {
  const GlacierMenuLabel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = GlacierTheme.of(context);
    final size = t.fontSize('xs');
    final page = glacierPanelTextStyle(context);
    // The heading sets no line height, so it keeps the page's, which is the face's own (`normal`).
    final style = TextStyle(
      inherit: false,
      color: t.color('glacier-text-subtle'),
      fontFamily: page.fontFamily,
      fontFamilyFallback: page.fontFamilyFallback,
      fontFeatures: page.fontFeatures,
      fontSize: size,
      fontWeight: t.weight('semibold'),
      fontVariations: [FontVariation('wght', t.len('glacier-font-weight-semibold'))],
      letterSpacing: 0.04 * size,
      textBaseline: TextBaseline.alphabetic,
      decoration: TextDecoration.none,
    );
    final child = this.child;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: t.space(1), horizontal: t.space(3)),
      child: DefaultTextStyle(style: style, child: child is Text ? _uppercase(child) : child),
    );
  }

  /// The same [Text] with its words in capitals, still read out as they were written.
  static Widget _uppercase(Text text) {
    final data = text.data;
    if (data == null) return text;
    return Text(
      data.toUpperCase(),
      key: text.key,
      style: text.style,
      strutStyle: text.strutStyle,
      textAlign: text.textAlign,
      textDirection: text.textDirection,
      locale: text.locale,
      softWrap: text.softWrap,
      overflow: text.overflow,
      textScaler: text.textScaler,
      maxLines: text.maxLines,
      semanticsLabel: text.semanticsLabel ?? data,
      textWidthBasis: text.textWidthBasis,
      textHeightBehavior: text.textHeightBehavior,
      selectionColor: text.selectionColor,
    );
  }
}
