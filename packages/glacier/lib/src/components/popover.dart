import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../motion/motion.dart';
import '../tokens/theme.dart';
import '../tokens/tokens.dart';
import 'anchored_position.dart';
import '../plain.dart';

// ---------------------------------------------------------------------------------------------------------------------
// What Popover and Menu share: the trigger's handle, the glass, and the anchored layer both float their panels in.
// ---------------------------------------------------------------------------------------------------------------------

/// What a trigger is handed so it can wire itself up. The web kit cloned the trigger element and wrote its own
/// `onClick` and `aria-expanded` onto it; a widget cannot be rewritten from outside, so its builder is given the
/// pieces instead: `onPressed: trigger.toggle`.
@immutable
class GlacierTrigger {
  const GlacierTrigger({required this.isOpen, required this.toggle, required this.setOpen});

  /// `aria-expanded`.
  final bool isOpen;

  /// The click the web kit wired on: open if closed, closed if open.
  final VoidCallback toggle;
  final ValueChanged<bool> setOpen;
}

/// Builds the trigger, wired with what [GlacierTrigger] hands it.
typedef GlacierTriggerBuilder = Widget Function(BuildContext context, GlacierTrigger trigger);

/// Builds a panel for where it ended up. [position] is null on the first frame, before it has been measured.
typedef GlacierPanelBuilder = Widget Function(BuildContext context, AnchoredPosition? position);

/// `backdrop-filter: blur(<blur>) saturate(var(--glacier-glass-saturate))`, for a [BackdropFilter] under a clip.
///
/// CSS `blur(N)` takes the Gaussian's standard deviation itself (Filter Effects 1: "the value of the standard
/// deviation to the Gaussian function"), so sigma is N; it is a box shadow's blur radius that is twice its sigma.
/// The blur is the ordinary one under the panel's clip. A bounded blur (which reads nothing from outside the panel,
/// as a browser cuts the backdrop to the element's box first) would be the closer match, but on the Fold under
/// Impeller it filled only part of the panel (2026-10-07: a menu's glass stopped two thirds of the way across), so
/// what stands beside a panel may tint its outermost pixels.
ImageFilterConfig glacierGlassFilter(Tokens tokens, {double? blur}) {
  final sigma = blur ?? tokens.len('glacier-blur-lg');
  return ImageFilterConfig.compose(
    outer: ImageFilterConfig(ui.ColorFilter.saturation(tokens.number('glacier-glass-saturate'))),
    inner: ImageFilterConfig.blur(sigmaX: sigma, sigmaY: sigma),
  );
}

/// The text a panel starts from. The web kit portals its panels to the body, so they take the page's type and not
/// their trigger's; here that is the text style in force at the root overlay, in the kit's sans face and ink.
TextStyle glacierPanelTextStyle(BuildContext context) {
  final tokens = GlacierTheme.of(context);
  final page = Overlay.maybeOf(context, rootOverlay: true)?.context.getInheritedWidgetOfExactType<DefaultTextStyle>()?.style ?? const TextStyle();
  final fonts = tokens.families('glacier-font-sans');
  return page.copyWith(
    color: tokens.color('glacier-text'),
    fontFamily: fonts.isEmpty ? null : fonts.first,
    fontFamilyFallback: fonts.length > 1 ? [...fonts.skip(1), ...?page.fontFamilyFallback] : null,
    decoration: TextDecoration.none,
  );
}

/// The panels that make one floating thing: a menu and its flyouts. A press in any of them is a press inside all of
/// them (`data-menu-stack` in Menu.tsx).
class GlacierLayerStack {
  final Set<GlobalKey> _panels = {};

  /// `withinStack(event.target, stackId)`.
  bool holds(Iterable<HitTestEntry> path) {
    for (final key in _panels) {
      final box = key.currentContext?.findRenderObject();
      if (box != null && path.any((entry) => identical(entry.target, box))) return true;
    }
    return false;
  }
}

/// The anchored overlay Popover and Menu are both built on: [child] stays where it is on the page, and while [open]
/// a panel floats over everything, against [anchor] (or [child] itself), fading and growing in and out.
///
/// This is the part of Popover.tsx and of Menu.tsx's `MenuPanel` that the two repeat: `createPortal(..., document.body)`
/// is an [OverlayPortal] on the root overlay, `useAnchoredPosition` is [GlacierAnchored], the `motion.div` is the
/// presence below, and the `pointerdown` listener on the document is a route on the gesture binding that sees every
/// press, wherever it lands.
///
/// The panel is kept in the tree after [open] turns false until it has faded (`mounted` in the React), and is then
/// taken out.
class GlacierAnchoredLayer extends StatefulWidget {
  const GlacierAnchoredLayer({
    super.key,
    required this.open,
    this.anchor,
    this.placement = Placement.bottomStart,
    this.offset = 8,
    this.padding = 8,
    this.matchWidth = false,
    this.constraints = const BoxConstraints(),
    this.stack,
    this.fades = true,
    this.onPressOutside,
    this.onBack,
    required this.panel,
    required this.child,
  });

  /// The opacity the panel this is called from is coming or going at, for a panel whose layer was told not to fade
  /// it and which fades itself (`fades: false`).
  static Animation<double> opacityOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_PresenceScope>()?.opacity ?? kAlwaysCompleteAnimation;

  final bool open;

  /// What the panel hangs from. Left out, it is [child].
  final GlacierAnchor? anchor;
  final Placement placement;
  final double offset;
  final double padding;
  final bool matchWidth;
  final BoxConstraints constraints;

  /// The panels a press may land in without being a press outside this one.
  final GlacierLayerStack? stack;

  /// Whether the layer fades the panel itself, as a `motion.div` wrapped round a glass surface does: the glass then
  /// has nothing behind it to blur until it has arrived, as in a browser, where an element that is fading is the
  /// whole backdrop of what is inside it. A panel that is its own glass (`.menu`) blurs the page all the way in and
  /// out; it passes false, and fades itself by [opacityOf], its backdrop filter with it.
  final bool fades;

  /// A press anywhere but the panel, the anchor and the [stack], as it goes down. The press still does whatever it
  /// would have done to what is under it.
  final VoidCallback? onPressOutside;

  /// The system's back gesture, while open. Of the layers that are open, the one opened last hears it.
  final VoidCallback? onBack;

  final GlacierPanelBuilder panel;
  final Widget child;

  @override
  State<GlacierAnchoredLayer> createState() => _GlacierAnchoredLayerState();
}

class _GlacierAnchoredLayerState extends State<GlacierAnchoredLayer> with WidgetsBindingObserver {
  /// The open layers that answer the back gesture, the one opened last at the end.
  static final List<_GlacierAnchoredLayerState> _backs = [];

  OverlayPortalController _portal = OverlayPortalController();
  final GlobalKey _selfKey = GlobalKey(debugLabel: 'GlacierAnchoredLayer child');
  final GlobalKey _panelKey = GlobalKey(debugLabel: 'GlacierAnchoredLayer panel');

  /// Whether the panel is in the overlay: from opening until its exit has finished.
  bool _mounted = false;

  /// Whether the global pointer route for presses outside is on.
  bool _listening = false;

  /// Where the panel was last placed; null until it has been measured.
  AnchoredPosition? _position;

  GlacierAnchor get _anchor => widget.anchor ?? GlacierAnchor.key(_selfKey);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.stack?._panels.add(_panelKey);
    if (widget.open) _mount();
    _sync();
  }

  @override
  void didUpdateWidget(GlacierAnchoredLayer old) {
    super.didUpdateWidget(old);
    if (!identical(old.stack, widget.stack)) {
      old.stack?._panels.remove(_panelKey);
      widget.stack?._panels.add(_panelKey);
    }
    if (widget.open && !_mounted) _mount();
    _sync();
  }

  /// `setMounted(true)`. A portal may not be shown while the tree is building, which is when this hears that it is
  /// open; a fresh controller that was told to show before it was attached is shown as it attaches, on top.
  void _mount() {
    _mounted = true;
    _portal = OverlayPortalController()..show();
  }

  /// The panel has faded: it comes out of the overlay, unless it was opened again meanwhile.
  void _onExitComplete() {
    if (!mounted || widget.open || !_mounted) return;
    setState(() {
      _mounted = false;
      _position = null;
    });
    _portal.hide();
    _sync();
  }

  /// The listeners the React hung on the document while the panel was mounted.
  void _sync() {
    final listen = _mounted && widget.onPressOutside != null;
    if (listen != _listening) {
      _listening = listen;
      final router = GestureBinding.instance.pointerRouter;
      if (listen) {
        router.addGlobalRoute(_onPointer);
      } else {
        router.removeGlobalRoute(_onPointer);
      }
    }
    final back = _mounted && widget.open && widget.onBack != null;
    if (!back) {
      _backs.remove(this);
    } else if (!_backs.contains(this)) {
      _backs.add(this);
    }
  }

  /// Every press on the screen: one that lands on none of the panel, the anchor and the stack is a press outside.
  void _onPointer(PointerEvent event) {
    if (event is! PointerDownEvent || !_mounted) return;
    final outside = widget.onPressOutside;
    if (outside == null) return;
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, event.position, event.viewId);
    final path = result.path.toList(growable: false);
    final panel = _panelKey.currentContext?.findRenderObject();
    if (panel != null && path.any((entry) => identical(entry.target, panel))) return;
    if (_anchor.holds(path, event.position)) return;
    if (widget.stack?.holds(path) ?? false) return;
    outside();
  }

  bool get _hearsBack => _backs.isNotEmpty && identical(_backs.last, this);

  /// Back where there is no route to ask: a tree with no navigator. Under one, the [PopScope] below is asked.
  @override
  Future<bool> didPopRoute() async {
    if (!_hearsBack || context.findAncestorStateOfType<NavigatorState>() != null) return false;
    widget.onBack?.call();
    return true;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.stack?._panels.remove(_panelKey);
    if (_listening) GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    _backs.remove(this);
    super.dispose();
  }

  void _onPosition(AnchoredPosition next) {
    if (!mounted || next == _position) return;
    setState(() => _position = next);
  }

  Widget _buildOverlay(BuildContext context) {
    return PopScope<Object?>(
      canPop: !(widget.open && widget.onBack != null),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _hearsBack) widget.onBack?.call();
      },
      child: GlacierAnchored(
        key: _panelKey,
        anchor: _anchor,
        placement: widget.placement,
        offset: widget.offset,
        padding: widget.padding,
        matchWidth: widget.matchWidth,
        constraints: widget.constraints,
        onChange: _onPosition,
        child: _Presence(
          open: widget.open,
          origin: _position?.transformOrigin ?? Alignment.center,
          fades: widget.fades,
          onExitComplete: _onExitComplete,
          child: widget.panel(context, _position),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _portal,
      overlayLocation: OverlayChildLocation.rootOverlay,
      // `createPortal(…, document.body)`: the panel is the page's own child, whatever scope its trigger is in.
      overlayChildBuilder: (context) => GlacierRootScope(child: Builder(builder: _buildOverlay)),
      child: KeyedSubtree(key: _selfKey, child: widget.child),
    );
  }
}

/// A panel's opacity, scale and lift at a moment of its coming or going.
class _Pose {
  const _Pose(this.opacity, this.scale, this.y);
  final double opacity, scale, y;

  /// The pose part of the way from [a] to [b].
  static _Pose lerp(_Pose a, _Pose b, double t) => _Pose(a.opacity + (b.opacity - a.opacity) * t, a.scale + (b.scale - a.scale) * t, a.y + (b.y - a.y) * t);
}

/// The `motion.div` both panels are:
/// `initial={{ opacity: 0, scale: 0.96, y: -4 }}`, `animate` to `{ opacity: 1, scale: 1, y: 0 }` while open and to
/// `{ opacity: 0, scale: 0.98, y: -2 }` once closed, over `transition(Speed.Fast, Ease.Out)`, each change starting
/// from wherever the last one had got to; with reduced motion it only fades, in no time. The scale grows out of
/// [origin], the `transform-origin` the position wrote.
class _Presence extends StatefulWidget {
  const _Presence({required this.open, required this.origin, required this.fades, required this.onExitComplete, required this.child});

  final bool open;
  final Alignment origin;
  final bool fades;
  final VoidCallback onExitComplete;
  final Widget child;

  @override
  State<_Presence> createState() => _PresenceState();
}

class _PresenceState extends State<_Presence> with SingleTickerProviderStateMixin {
  static const _shown = _Pose(1, 1, 0);
  static const _hidden = _Pose(0, 0.98, -2);

  late final AnimationController _controller = AnimationController(vsync: this)..addStatusListener(_onStatus);
  late final _PresenceOpacity _opacity = _PresenceOpacity(this);
  Curve _curve = Curves.linear;

  /// The poses the running change goes between; [_now] is where it has got to.
  _Pose _from = _shown, _to = _shown;
  bool _started = false;

  _Pose get _now => _Pose.lerp(_from, _to, _curve.transform(_controller.value));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final reduce = GlacierTheme.of(context).reducedMotion;
    _from = reduce ? const _Pose(0, 1, 0) : const _Pose(0, 0.96, -4);
    _run();
  }

  @override
  void didUpdateWidget(_Presence old) {
    super.didUpdateWidget(old);
    if (old.open == widget.open) return;
    _from = _now;
    _run();
  }

  /// Sets off from [_from] to shown or hidden, as [_Presence.open] says, at the fast speed.
  void _run() {
    final timing = transition(GlacierTheme.of(context), Speed.fast, Ease.out);
    _curve = timing.curve;
    _to = widget.open ? _shown : _hidden;
    _controller.duration = timing.duration;
    _controller.forward(from: 0);
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || widget.open) return;
    // `onAnimationComplete`. After the frame, since taking the panel out of the tree is not for the middle of one.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.open) widget.onExitComplete();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _PresenceScope(
      opacity: _opacity,
      child: AnimatedBuilder(
        animation: _controller,
        child: widget.child,
        builder: (context, child) {
          final pose = _now;
          final moved = Transform(
            alignment: widget.origin,
            transform: Matrix4.identity()
              ..translateByDouble(0, pose.y, 0, 1)
              ..scaleByDouble(pose.scale, pose.scale, 1, 1),
            child: child,
          );
          // In the tree to a screen reader from the frame it mounts, as an element at `opacity: 0` is.
          return widget.fades ? Opacity(opacity: pose.opacity.clamp(0.0, 1.0), alwaysIncludeSemantics: true, child: moved) : moved;
        },
      ),
    );
  }
}

/// The presence's opacity as an animation of its own, for a panel that fades itself.
class _PresenceOpacity extends Animation<double> with AnimationWithParentMixin<double> {
  _PresenceOpacity(this._presence);
  final _PresenceState _presence;

  @override
  Animation<double> get parent => _presence._controller;

  @override
  double get value => _presence._now.opacity.clamp(0.0, 1.0);
}

/// Hands the presence's opacity to the panel inside it ([GlacierAnchoredLayer.opacityOf]).
class _PresenceScope extends InheritedWidget {
  const _PresenceScope({required this.opacity, required super.child});
  final Animation<double> opacity;

  @override
  bool updateShouldNotify(_PresenceScope old) => !identical(old.opacity, opacity);
}

// ---------------------------------------------------------------------------------------------------------------------
// ArrowGlass
// ---------------------------------------------------------------------------------------------------------------------

/// The one-piece glass surface behind an anchored panel: a rounded rectangle and its trigger-facing tip as a single
/// outline, so one backdrop sample and one tint cover both and no seam can exist between them.
///
/// Ports internal/ArrowGlass.tsx and ArrowGlass.module.css, layer for layer under [child]: the underlay (the box in
/// `oklch(0.1 0.01 260 / 0.55)`, blurred by 14px, cut to the outline and set 6px down), the glass (`--glacier-glass-thick`
/// over a backdrop blurred by `--glacier-blur-lg` and saturated, cut to the outline), and the outline stroked with
/// the hairline in `--glacier-glass-border`. [placement] is the resolved one from the position; null draws nothing,
/// as the React draws nothing before it has measured.
///
/// The underlay is drawn as a browser draws it, which is filter first and clip second: what is cut to the outline is
/// the blurred box, so it reads as a dark sheet under the glass with a lip below it, not as a shadow spreading out.
class GlacierArrowGlass extends StatelessWidget {
  const GlacierArrowGlass({
    super.key,
    required this.placement,
    this.tipAt,
    this.tip = 6,
    this.tipHalf = 7,
    this.tipInset = 14,
    this.radius,
    this.blur,
    required this.child,
  });

  /// Resolved placement from the position; null hides the surface.
  final Placement? placement;

  /// Trigger center projected onto the tipped edge, in panel px.
  final double? tipAt;

  /// Tip protrusion depth in px.
  final double tip;

  /// Half the tip's base width in px.
  final double tipHalf;

  /// Distance of the tip center from the panel corner for -start / -end.
  final double tipInset;

  /// `--arrow-glass-radius`: the panel's corner radius. Left out, it is `--glacier-radius-lg`, as Popover sets it.
  final double? radius;

  /// `--arrow-glass-blur`: hosts can soften the material. Left out, it is `--glacier-blur-lg`.
  final double? blur;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = GlacierTheme.of(context);
    final placement = this.placement;
    Widget surface = const SizedBox.shrink();
    if (placement != null) {
      final side = placement.physicalSide(TextDirection.ltr);
      final vertical = side == PhysicalSide.top || side == PhysicalSide.bottom;
      final r = radius ?? t.radius('lg');
      // The outline for a box that holds the panel and its tip: the panel is the box less the tip's depth.
      ArrowGlassShape shape(Size box) => buildArrowGlassShape(
            width: box.width - (vertical ? 0 : tip),
            height: box.height - (vertical ? tip : 0),
            radius: r,
            placement: placement,
            tipAt: tipAt,
            tip: tip,
            tipHalf: tipHalf,
            tipInset: tipInset,
          );
      final key = Object.hash(placement, tipAt, tip, tipHalf, tipInset, r);
      // The box the outline is drawn in: the panel, and the strip the tip reaches into on the side facing the anchor.
      Widget boxed(Widget layer) => Positioned(
            left: side == PhysicalSide.right ? -tip : 0,
            top: side == PhysicalSide.bottom ? -tip : 0,
            right: side == PhysicalSide.left ? -tip : 0,
            bottom: side == PhysicalSide.top ? -tip : 0,
            child: layer,
          );
      surface = Stack(
        clipBehavior: Clip.none,
        children: [
          boxed(CustomPaint(painter: _UnderlayPainter(shape, key, t.colorOf('oklch(0.1 0.01 260 / 0.55)')))),
          boxed(
            ClipPath(
              clipper: _OutlineClipper(shape, key),
              child: BackdropFilter(enabled: !glacierPlain, 
                filterConfig: glacierGlassFilter(t, blur: blur),
                child: ColoredBox(color: t.color('glacier-glass-thick'), child: const SizedBox.expand()),
              ),
            ),
          ),
          boxed(CustomPaint(painter: _OutlinePainter(shape, key, t.color('glacier-glass-border'), t.len('glacier-hairline')))),
        ],
      );
    }
    return Stack(
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: [
        // `.host { position: absolute; inset: 0; pointer-events: none }`
        Positioned.fill(child: IgnorePointer(child: ExcludeSemantics(child: surface))),
        child,
      ],
    );
  }
}

/// The outline for a box of a size. The painters and the clipper below compare [key], a hash of everything else
/// the outline is made from, to know when it has changed.
typedef _ShapeOf = ArrowGlassShape Function(Size box);

/// Cuts the glass to the outline.
class _OutlineClipper extends CustomClipper<Path> {
  _OutlineClipper(this.shape, this.key);
  final _ShapeOf shape;
  final Object key;

  @override
  Path getClip(Size size) => shape(size).path;

  @override
  bool shouldReclip(_OutlineClipper old) => old.key != key;
}

/// `.shadow { background: oklch(0.1 0.01 260 / 0.55); filter: blur(14px); transform: translateY(6px) }` with the
/// outline as its `clip-path`. A filter is applied before a clip, so this is the blurred box seen through the outline.
class _UnderlayPainter extends CustomPainter {
  _UnderlayPainter(this.shape, this.key, this.color);
  final _ShapeOf shape;
  final Object key;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(0, 6);
    canvas.clipPath(shape(size).path);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = color
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_UnderlayPainter old) => old.key != key || old.color != color;
}

/// `.outline path { stroke: var(--glacier-glass-border); stroke-width: var(--glacier-hairline) }`.
class _OutlinePainter extends CustomPainter {
  _OutlinePainter(this.shape, this.key, this.color, this.width);
  final _ShapeOf shape;
  final Object key;
  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      shape(size).path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_OutlinePainter old) => old.key != key || old.color != color || old.width != width;
}

// ---------------------------------------------------------------------------------------------------------------------
// Popover
// ---------------------------------------------------------------------------------------------------------------------

/// What opens a popover's panel (`popoverOpenOns` of @glacier/spec).
enum PopoverOpenOn { press, hover }

/// A pointer crossing from the trigger to the panel passes over the gap between them, so leaving either one starts a
/// countdown the other can cancel rather than shutting the panel under the cursor on its way in.
const Duration _hoverGrace = Duration(milliseconds: 150);

/// A floating panel anchored to a trigger. The panel floats over everything else on the root overlay, flips and
/// clamps to stay on screen, and closes on outside press and Escape.
///
/// Ports organisms/Popover/Popover.tsx and Popover.module.css. The props are the React's by name: [trigger],
/// [placement], [open] / [defaultOpen] / [onOpenChange] (controlled when [open] is given), [openOn], [ariaLabel]
/// for `aria-label`, and [child] for `children`.
///
/// Differs from the React:
/// - [trigger] is a builder, handed what the React wrote onto the element it cloned: wire `trigger.toggle` to the
///   press. With `openOn: hover` the trigger keeps its own press and needs nothing wired.
/// - [anchor] is new: something already on the page to hang from, in place of (or as well as) a trigger.
/// - [minWidth], [maxWidth] and [padding] stand in for `className`, each defaulting to the kit's own rule.
/// - Android's back gesture closes it.
/// - `onOpenChange` is called when the state changes, and not again for a second way of closing at the same moment
///   (the React calls it twice for an Escape pressed inside the panel).
/// - Escape pressed inside a panel that opens on hover closes it. In the React the focus Escape hands back to the
///   trigger is itself a reason to open, so the panel stayed.
/// - `aria-haspopup` has no counterpart in Flutter's semantics; `aria-expanded` and `aria-controls` are carried.
/// - The panel takes the page's root tokens ([GlacierRootScope]), not those in force at the trigger, as a portalled
///   panel took the body's.
class GlacierPopover extends StatefulWidget {
  const GlacierPopover({
    super.key,
    this.trigger,
    this.anchor,
    this.placement = Placement.bottomStart,
    this.open,
    this.defaultOpen = false,
    this.onOpenChange,
    this.openOn = PopoverOpenOn.press,
    this.ariaLabel,
    this.minWidth,
    this.maxWidth,
    this.padding,
    this.child,
  }) : assert(trigger != null || anchor != null, 'A popover hangs from its trigger or from an anchor.');

  /// The element that toggles the popover.
  final GlacierTriggerBuilder? trigger;

  /// What the panel hangs from, where that is not the trigger.
  final GlacierAnchor? anchor;

  /// Where to place the panel relative to the trigger.
  final Placement placement;
  final bool? open;
  final bool defaultOpen;
  final ValueChanged<bool>? onOpenChange;

  /// What opens the panel. Hover opens it on pointer and on focus and leaves the trigger's press alone, for a
  /// trigger that already does something of its own. The panel does not take focus when it opens that way; Tab from
  /// the trigger hands focus over.
  final PopoverOpenOn openOn;

  /// Accessible label for the panel when it has no heading.
  final String? ariaLabel;

  /// `.panel { min-width: 12rem }`.
  final double? minWidth;

  /// `.panel { max-width: min(24rem, calc(100vw - 2rem)) }`.
  final double? maxWidth;

  /// `.panel { padding: var(--glacier-space-2) }`.
  final EdgeInsetsGeometry? padding;

  final Widget? child;

  @override
  State<GlacierPopover> createState() => _GlacierPopoverState();
}

class _GlacierPopoverState extends State<GlacierPopover> {
  final GlobalKey _triggerKey = GlobalKey(debugLabel: 'GlacierPopover trigger');
  final FocusNode _triggerNode = FocusNode(debugLabel: 'GlacierPopover trigger', canRequestFocus: false, skipTraversal: true);
  final FocusNode _panelNode = FocusNode(debugLabel: 'GlacierPopover panel', skipTraversal: true);
  late bool _internal = widget.defaultOpen;

  /// The hover's grace running: the panel closes when it ends unless the pointer or the focus comes back.
  Timer? _closeTimer;

  /// Set while Escape puts focus back on a hover trigger, so that focus does not open the panel again.
  bool _handingBack = false;

  bool get _isOpen => widget.open ?? _internal;
  bool get _hover => widget.openOn == PopoverOpenOn.hover;
  GlacierAnchor get _anchor => widget.anchor ?? GlacierAnchor.key(_triggerKey);
  String get _panelId => 'glacier-popover-${identityHashCode(this)}';

  void _setOpenState(bool next) {
    if (!mounted || next == _isOpen) return;
    if (widget.open == null) setState(() => _internal = next);
    widget.onOpenChange?.call(next);
  }

  /// Takes back a close that was on its way.
  void _holdOpen() {
    _closeTimer?.cancel();
    _closeTimer = null;
  }

  void _show() {
    _holdOpen();
    _setOpenState(true);
  }

  /// Closes after the hover's grace, unless [_holdOpen] or [_show] comes first.
  void _hideSoon() {
    _holdOpen();
    _closeTimer = Timer(_hoverGrace, () {
      _closeTimer = null;
      _setOpenState(false);
    });
  }

  /// Escape: closed, and the keyboard back on the trigger. A trigger that opens on focus is not to open again for
  /// the focus this hands it.
  void _dismiss() {
    _setOpenState(false);
    _handingBack = _hover;
    _anchor.focus();
    // The focus manager tells the trigger of its focus in a microtask it has already queued; this one is after it.
    scheduleMicrotask(() => _handingBack = false);
  }

  @override
  void dispose() {
    _holdOpen();
    _triggerNode.dispose();
    _panelNode.dispose();
    super.dispose();
  }

  /// The trigger as built, with the hover, focus and Tab handling round it where the panel opens on hover.
  Widget _buildTrigger(BuildContext context) {
    final build = widget.trigger;
    if (build == null) return const SizedBox.shrink();
    Widget child = build(context, GlacierTrigger(isOpen: _isOpen, toggle: () => _setOpenState(!_isOpen), setOpen: _setOpenState));
    if (_hover) {
      child = Listener(
        // A touch has no hover: its landing is the pointer's arrival, and its leaving is not a reason to close,
        // since the tap that opened the panel would be the gesture that shut it again.
        onPointerDown: (event) {
          if (event.kind == PointerDeviceKind.touch) _show();
        },
        child: MouseRegion(onEnter: (_) => _show(), onExit: (_) => _hideSoon(), child: child),
      );
      child = Focus(
        focusNode: _triggerNode,
        canRequestFocus: false,
        skipTraversal: true,
        includeSemantics: false,
        onFocusChange: (focused) {
          final handedBack = _handingBack;
          _handingBack = false;
          if (focused) {
            if (!handedBack) _show();
          } else if (!_panelNode.hasFocus) {
            _hideSoon();
          }
        },
        onKeyEvent: (node, event) {
          // The panel is not where the next Tab would land, so Tab from the trigger is walked across by hand.
          final tab = event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.tab && !HardwareKeyboard.instance.isShiftPressed;
          if (!tab || !_isOpen || _panelNode.context == null) return KeyEventResult.ignored;
          _panelNode.requestFocus();
          return KeyEventResult.handled;
        },
        child: child,
      );
    }
    return Semantics(
      expanded: _isOpen,
      controlsNodes: _isOpen ? {_panelId} : null,
      child: KeyedSubtree(key: _triggerKey, child: child),
    );
  }

  /// The panel: the arrowed glass round the content, as a dialog with a focus of its own and Escape on it.
  Widget _buildPanel(BuildContext context, AnchoredPosition? position) {
    final t = GlacierTheme.of(context);
    // The panel's box takes every press that lands in it, as an element does, whatever its content leaves bare.
    Widget panel = Listener(
      behavior: HitTestBehavior.opaque,
      child: GlacierArrowGlass(
        placement: position?.placement,
        tipAt: position?.arrowOffset,
        child: DefaultTextStyle(
          style: glacierPanelTextStyle(context),
          child: Padding(padding: widget.padding ?? EdgeInsets.all(t.space(2)), child: widget.child),
        ),
      ),
    );
    if (_hover) {
      panel = Listener(
        onPointerDown: (event) {
          if (event.kind == PointerDeviceKind.touch) _holdOpen();
        },
        onPointerUp: (event) {
          if (event.kind == PointerDeviceKind.touch) _hideSoon();
        },
        onPointerCancel: (event) {
          if (event.kind == PointerDeviceKind.touch) _hideSoon();
        },
        child: MouseRegion(onEnter: (_) => _holdOpen(), onExit: (_) => _hideSoon(), child: panel),
      );
    }
    return Semantics(
      role: SemanticsRole.dialog,
      identifier: _panelId,
      label: widget.ariaLabel,
      container: true,
      explicitChildNodes: true,
      child: FocusTraversalGroup(
        child: Focus(
          focusNode: _panelNode,
          skipTraversal: true,
          // The dialog is one node to a screen reader, and what is in it is that node's own children.
          includeSemantics: false,
          onKeyEvent: (node, event) {
            if (event.logicalKey != LogicalKeyboardKey.escape) return KeyEventResult.ignored;
            if (event is! KeyUpEvent) _dismiss();
            return KeyEventResult.handled;
          },
          // Tabbing out of a hovered panel is done with it; a press-opened one is not, since focus leaving it was
          // never what closed it.
          onFocusChange: (focused) {
            if (_hover && !focused && !_triggerNode.hasFocus) _hideSoon();
          },
          child: _PopoverEars(owner: this, child: panel),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = GlacierTheme.of(context);
    final minWidth = widget.minWidth ?? t.lenOf('12rem');
    final maxWidth = widget.maxWidth ?? t.lenOf('min(24rem, calc(100vw - 2rem))');
    return GlacierAnchoredLayer(
      open: _isOpen,
      anchor: widget.anchor,
      placement: widget.placement,
      // offset leaves room for the arrow tip plus a small visual gap
      offset: 12,
      // `min-width` has the last word over `max-width`, as it does in CSS.
      constraints: BoxConstraints(minWidth: minWidth, maxWidth: maxWidth < minWidth ? minWidth : maxWidth),
      onPressOutside: () => _setOpenState(false),
      onBack: () => _setOpenState(false),
      panel: _buildPanel,
      child: _buildTrigger(context),
    );
  }
}

/// What the React's effect did for as long as the panel was mounted: take focus, if a press asked for the panel, and
/// listen for Escape on the document, wherever the keyboard is.
class _PopoverEars extends StatefulWidget {
  const _PopoverEars({required this.owner, required this.child});
  final _GlacierPopoverState owner;
  final Widget child;

  @override
  State<_PopoverEars> createState() => _PopoverEarsState();
}

class _PopoverEarsState extends State<_PopoverEars> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    // A panel the pointer opened must not take focus off whatever the keyboard was on; one that was asked for by a
    // press is where the user just went.
    if (!widget.owner._hover) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.owner._panelNode.requestFocus();
      });
    }
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyUpEvent && event.logicalKey == LogicalKeyboardKey.escape) widget.owner._dismiss();
    return false;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
