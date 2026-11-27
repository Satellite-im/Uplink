import 'dart:math' as math;
import 'dart:ui' show SemanticsRole;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../haptics/haptics.dart';
import '../tokens/theme.dart';
import '../tokens/tokens.dart';
import 'pressable.dart';

/// The kit's densities (`densityModes`, `@glacier/tokens`' `Density`), tightest first.
enum GlacierDensityMode {
  extraCompact('extra-compact', 'Extra Compact'),
  compact('compact', 'Compact'),
  comfortable('comfortable', 'Default'),
  spacious('spacious', 'Comfortable'),
  moreSpace('more-space', 'More Space');

  const GlacierDensityMode(this.token, this.label);

  /// The `data-density` value: what `GlacierTheme(attrs: {'density': ...})` takes.
  final String token;

  /// The kit's English name for it (`kitMessages.density*`). Note that `comfortable` is shown as "Default" and
  /// `spacious` as "Comfortable".
  final String label;
}

/// Port of `@glacier/react`'s `DensitySelector` (`molecules/DensitySelector/DensitySelector.tsx`, with
/// `DensitySelector.module.css`): a scroll-safe visual density picker with radio-card keyboard interactions.
///
/// Five cards in a row, each a miniature window drawn at that density over its name. The row is as wide as its
/// place and never narrower than 29rem; in less room than that it scrolls sideways inside the kit's scroll area,
/// which fades the edge there is more beyond and draws its own scrollbar along the bottom. Controlled only: [value]
/// and [onValueChange]. Arrow keys, Home and End move the selection and the focus with it, round the ends, and
/// bring the card into view; Tab stops once, on the selected card.
///
/// What differs from the React original:
/// - The names are English unless [labels] replaces them; the kit's locale provider is not ported.
/// - The kit's `ScrollArea` is not a Flutter widget yet, so the part of it this uses is drawn here: the horizontal
///   viewport, its edge fades, and the scrollbar with its track (press or drag it to scroll). The viewport itself is
///   not a keyboard stop; the cards are, and they scroll themselves into view. The scrollbar keeps `ScrollArea`'s own
///   arithmetic for a press, under which the far end of the track is short of the far end of the content.
/// - A disabled option is as opaque as the web one is: the stylesheet dims it by `--glacier-opacity-disabled`,
///   which no token sheet defines, so the declaration is void there. It is read here the same way, and will dim the
///   day the token exists.
class GlacierDensitySelector extends StatefulWidget {
  const GlacierDensitySelector({
    super.key,
    required this.value,
    required this.onValueChange,
    this.labels,
    this.disabled = false,
    required this.ariaLabel,
  });

  /// The active density token value.
  final GlacierDensityMode value;

  /// Called when a density card is selected.
  final ValueChanged<GlacierDensityMode> onValueChange;

  /// Optional label overrides keyed by density value.
  final Map<GlacierDensityMode, Widget>? labels;

  /// Disables every density option.
  final bool disabled;

  /// `aria-label`: the accessible name for the radio group.
  final String ariaLabel;

  @override
  State<GlacierDensitySelector> createState() => _GlacierDensitySelectorState();
}

class _GlacierDensitySelectorState extends State<GlacierDensitySelector> {
  static const _modes = GlacierDensityMode.values;

  final ScrollController _scroll = ScrollController();

  /// Keeps the one scroll view (and its place) whether or not the fades and the scrollbar are built round it.
  final GlobalKey _viewportKey = GlobalKey();

  /// A focus node a card, with the group's keys on it.
  late final List<FocusNode> _nodes = [
    for (final mode in _modes) FocusNode(debugLabel: 'density ${mode.token}', onKeyEvent: (node, event) => _onKey(mode, event)),
  ];

  @override
  void initState() {
    super.initState();
    _syncNodes();
  }

  @override
  void didUpdateWidget(GlacierDensitySelector old) {
    super.didUpdateWidget(old);
    _syncNodes();
  }

  @override
  void dispose() {
    _scroll.dispose();
    for (final node in _nodes) {
      node.dispose();
    }
    super.dispose();
  }

  /// `tabIndex={selected ? 0 : -1}`: the group is one Tab stop.
  void _syncNodes() {
    for (final mode in _modes) {
      _nodes[mode.index].skipTraversal = mode != widget.value;
    }
  }

  /// Reports a card chosen. From the keyboard ([focus]) the card also takes the focus and is scrolled into view.
  void _select(GlacierDensityMode mode, {bool focus = false}) {
    if (widget.disabled) return;
    widget.onValueChange(mode);
    if (!focus) return;
    final node = _nodes[mode.index];
    node.requestFocus();
    // `scrollIntoView({ block: 'nearest', inline: 'nearest' })`: no further than it takes to show the card.
    final card = node.context;
    if (card == null) return;
    Scrollable.ensureVisible(card, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
    Scrollable.ensureVisible(card, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
  }

  /// The arrows step to the next or previous card, round the ends; Home and End go to the first and the last.
  KeyEventResult _onKey(GlacierDensityMode mode, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final count = _modes.length;
    int? next;
    if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.arrowDown) next = (mode.index + 1) % count;
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowUp) next = (mode.index - 1 + count) % count;
    if (key == LogicalKeyboardKey.home) next = 0;
    if (key == LogicalKeyboardKey.end) next = count - 1;
    if (next == null) return KeyEventResult.ignored;
    _select(_modes[next], focus: true);
    return KeyEventResult.handled;
  }

  /// One card: the preview over its name, as a radio of the group.
  Widget _option(Tokens t, GlacierDensityMode mode) {
    final selected = mode == widget.value;
    final disabled = widget.disabled;
    // `opacity: var(--glacier-opacity-disabled)`, which is no opacity at all while the token is undefined.
    final dimmed = t.raw('glacier-opacity-disabled') == null ? 1.0 : t.len('glacier-opacity-disabled');
    final style = Tokens.resized(t.text('sm', weight: 'medium', color: t.color(selected ? 'glacier-text' : 'glacier-text-muted')), t.lenOf('0.675rem'));
    return Semantics(
      container: true,
      inMutuallyExclusiveGroup: true,
      checked: selected,
      enabled: !disabled,
      // The tap and the focus come up from the pressable's own detectors into this node.
      child: GlacierPressable(
        onPressed: disabled ? null : () => _select(mode),
        haptic: HapticKind.selection,
        focusNode: _nodes[mode.index],
        excludeSemantics: true,
        builder: (context, state) => Opacity(
          opacity: disabled ? dimmed.clamp(0.0, 1.0) : 1,
          child: GlacierFocusRing(
            visible: state.focused,
            radius: t.radius('md'),
            offset: -1,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: t.space(1)),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ExcludeSemantics(child: _DensityPreview(mode: mode, selected: selected, hovered: state.hovered)),
                  SizedBox(height: t.space(2)),
                  SizedBox(
                    width: double.infinity,
                    child: DefaultTextStyle(
                      style: style,
                      textAlign: TextAlign.center,
                      softWrap: false,
                      overflow: TextOverflow.visible,
                      child: widget.labels?[mode] ?? Text(mode.label),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = GlacierTheme.of(context);
    final gap = t.space(2);
    const edge = 2.0; // `.options { padding: 2px }`
    final count = _modes.length;

    return Semantics(
      container: true,
      explicitChildNodes: true,
      role: SemanticsRole.radioGroup,
      label: widget.ariaLabel,
      enabled: widget.disabled ? false : null,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // `width: 100%; min-width: 29rem`, in columns of `minmax(5rem, 1fr)`.
          final floor = t.lenOf('29rem');
          final viewport = constraints.hasBoundedWidth ? constraints.maxWidth : floor;
          final column = math.max(t.lenOf('5rem'), (math.max(viewport, floor) - edge * 2 - gap * (count - 1)) / count);
          final content = math.max(math.max(viewport, floor), column * count + gap * (count - 1) + edge * 2);
          final reach = math.max(content - viewport, 0.0);
          final scrolls = reach > 1;

          final Widget options = SizedBox(
            width: content,
            child: Padding(
              // Room for the scrollbar under the cards, whenever there is one.
              padding: EdgeInsets.fromLTRB(edge, edge, edge, edge + (scrolls ? t.space(4) : 0)),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final mode in _modes) ...[
                    if (mode.index > 0) SizedBox(width: gap),
                    SizedBox(width: column, child: _option(t, mode)),
                  ],
                ],
              ),
            ),
          );

          final Widget view = SingleChildScrollView(
            key: _viewportKey,
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            child: options,
          );
          if (!scrolls) return SizedBox(width: viewport, child: view);

          return SizedBox(
            width: viewport,
            child: AnimatedBuilder(
              animation: _scroll,
              builder: (context, _) {
                final at = (_scroll.hasClients ? _scroll.offset : 0.0).clamp(0.0, reach);
                return Stack(
                  alignment: Alignment.topLeft,
                  children: [
                    _EdgeFade(start: at > 1, end: reach - at > 1, width: t.space(6), child: view),
                    Positioned(
                      left: gap,
                      right: gap,
                      bottom: 0,
                      height: gap,
                      child: _Scrollbar(
                        viewport: viewport,
                        content: content,
                        at: at,
                        onScroll: (to) => _scroll.jumpTo(to),
                      ),
                    ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// `ScrollArea`'s fade masks, on the horizontal axis: the content dissolves over [width] toward whichever edge can
/// still scroll.
class _EdgeFade extends StatelessWidget {
  const _EdgeFade({required this.start, required this.end, required this.width, required this.child});
  final bool start, end;
  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.maybeOf(context) == TextDirection.rtl;
    final t = GlacierTheme.of(context);
    final clear = t.colorOf('transparent'), solid = t.colorOf('#000');
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) {
        final ramp = rect.width <= 0 ? 0.0 : (width / rect.width).clamp(0.0, 0.5);
        return LinearGradient(
          begin: rtl ? Alignment.centerRight : Alignment.centerLeft,
          end: rtl ? Alignment.centerLeft : Alignment.centerRight,
          colors: [start ? clear : solid, solid, solid, end ? clear : solid],
          stops: [0, ramp, 1 - ramp, 1],
        ).createShader(rect);
      },
      child: child,
    );
  }
}

/// `ScrollArea`'s own scrollbar, on the horizontal axis: a half-strength track with a thumb the size of the share of
/// the content that is in view, never under 12% of the track. A press or a drag along it scrolls to there.
class _Scrollbar extends StatelessWidget {
  const _Scrollbar({required this.viewport, required this.content, required this.at, required this.onScroll});
  final double viewport, content, at;
  final ValueChanged<double> onScroll;

  @override
  Widget build(BuildContext context) {
    final t = GlacierTheme.of(context);
    final rtl = Directionality.maybeOf(context) == TextDirection.rtl;
    final radius = BorderRadius.circular(t.radius('full'));
    final reach = math.max(content - viewport, 0.0);
    final share = viewport / math.max(content, 1);
    final thumb = math.min(1.0, math.max(0.12, share));
    final along = reach > 0 ? at / reach : 0.0;

    // Scrolls so the pointer is at the middle of the thumb (the share of the content in view), within the ends.
    void scrollFrom(Offset local, Size track) {
      if (track.width <= 0) return;
      final from = rtl ? track.width - local.dx : local.dx;
      onScroll((from / track.width - share / 2).clamp(0.0, 1.0) * reach);
    }

    return ExcludeSemantics(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Builder(
          builder: (context) => Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) => scrollFrom(event.localPosition, context.size ?? Size.zero),
            onPointerMove: (event) {
              if (event.down) scrollFrom(event.localPosition, context.size ?? Size.zero);
            },
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: t.colorOf('color-mix(in oklch, var(--glacier-border-strong) 50%, var(--glacier-surface))'),
                borderRadius: radius,
              ),
              child: Align(
                alignment: AlignmentDirectional(along * 2 - 1, 0),
                child: FractionallySizedBox(
                  widthFactor: thumb,
                  heightFactor: 1,
                  child: DecoratedBox(decoration: BoxDecoration(color: t.color('glacier-border-strong'), borderRadius: radius)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `DensityPreview`: a miniature window, its toolbar over a few lines of text, spaced as the density would space
/// them.
class _DensityPreview extends StatelessWidget {
  const _DensityPreview({required this.mode, required this.selected, required this.hovered});
  final GlacierDensityMode mode;
  final bool selected, hovered;

  @override
  Widget build(BuildContext context) {
    final t = GlacierTheme.of(context);
    final hairline = t.len('glacier-hairline');
    final radius = t.radius('md');
    final subtle = t.color('glacier-border-subtle');
    final surface = t.color('glacier-surface');
    // `.option:not(:disabled):hover .preview` outranks `.option[data-selected] .preview`: a hovered card's border
    // is the strong one even when it is the selected card, inside its accent ring.
    final border = t.color(hovered ? 'glacier-border-strong' : (selected ? 'glacier-accent-solid' : 'glacier-border'));
    final shadow = selected ? t.shadowOf('0 0 0 2px var(--glacier-accent-solid), var(--glacier-shadow-2)') : t.shadow('glacier-shadow-2');

    final Widget chrome = Container(
      constraints: BoxConstraints(minHeight: t.lenOf('1rem')),
      padding: EdgeInsets.symmetric(horizontal: t.lenOf('0.35rem')),
      decoration: BoxDecoration(
        color: t.color('glacier-surface-sunken'),
        border: Border(bottom: BorderSide(color: subtle, width: hairline)),
      ),
      child: Row(
        children: [
          // `.sidebarControl`, with its `::before` rule a third of the way along.
          Container(
            width: t.lenOf('0.72rem'),
            height: t.lenOf('0.56rem'),
            decoration: BoxDecoration(
              color: surface,
              border: Border.all(color: subtle, width: hairline),
              borderRadius: BorderRadius.circular(t.radius('xs')),
            ),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: FractionallySizedBox(
                widthFactor: 0.32,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(border: BorderDirectional(end: BorderSide(color: subtle, width: hairline))),
                ),
              ),
            ),
          ),
          SizedBox(width: t.lenOf('0.25rem')),
          // `.searchControl`, and the little ring in it.
          Expanded(
            child: Container(
              height: t.lenOf('0.56rem'),
              padding: EdgeInsetsDirectional.only(start: t.lenOf('0.14rem')),
              alignment: AlignmentDirectional.centerStart,
              decoration: BoxDecoration(
                color: surface,
                border: Border.all(color: subtle, width: hairline),
                borderRadius: BorderRadius.circular(t.radius('full')),
              ),
              child: Container(
                width: t.lenOf('0.2rem'),
                height: t.lenOf('0.2rem'),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: t.color('glacier-text-muted'), width: hairline),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    // `.canvas` and its `.line`s, by `data-mode`: the gap, the padding, a line's height, the title's, and whether
    // the short line is drawn.
    final (gap, padding, line, title, short) = switch (mode) {
      GlacierDensityMode.extraCompact => ('0.1rem', '0.3rem', '0.18rem', '0.24rem', true),
      GlacierDensityMode.compact => ('0.18rem', '0.36rem', '0.23rem', '0.32rem', true),
      GlacierDensityMode.comfortable => ('0.28rem', '0.45rem', '0.23rem', '0.32rem', true),
      GlacierDensityMode.spacious => ('0.38rem', '0.5rem', '0.23rem', '0.32rem', true),
      GlacierDensityMode.moreSpace => ('0.6rem', '0.6rem', '0.16rem', '0.22rem', false),
    };
    // One bar standing for a line of text: [width] is its share of the canvas.
    Widget stroke(double width, String height, String color) {
      final ink = t.color(color);
      return FractionallySizedBox(
        widthFactor: width,
        child: Container(
          height: t.lenOf(height),
          // `opacity: 0.72` on a flat bar is the same bar at 0.72 of its alpha.
          decoration: BoxDecoration(color: ink.withValues(alpha: ink.a * 0.72), borderRadius: BorderRadius.circular(t.radius('full'))),
        ),
      );
    }

    final between = SizedBox(height: t.lenOf(gap));
    final Widget canvas = Padding(
      padding: EdgeInsets.all(t.lenOf(padding)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          stroke(0.72, title, 'glacier-text'),
          SizedBox(height: t.lenOf('0.05rem')), // the title's `margin-bottom`
          between,
          stroke(1, line, 'glacier-text-muted'),
          if (short) ...[between, stroke(0.62, line, 'glacier-text-muted')],
          between,
          stroke(1, line, 'glacier-text-muted'),
        ],
      ),
    );

    return ConstrainedBox(
      // `width: min(100%, 5rem); aspect-ratio: 1.08`
      constraints: BoxConstraints(maxWidth: t.lenOf('5rem')),
      child: AspectRatio(
        aspectRatio: 1.08,
        child: AnimatedContainer(
          duration: t.duration('glacier-duration-fast'),
          curve: t.curve('glacier-ease-out'),
          transform: Matrix4.translationValues(0, hovered ? -t.len('glacier-space-px') : 0, 0),
          decoration: BoxDecoration(
            color: surface,
            border: Border.all(color: border, width: hairline),
            borderRadius: BorderRadius.circular(radius),
            boxShadow: shadow,
          ),
          // `overflow: hidden`, inside the border.
          child: ClipRRect(
            borderRadius: BorderRadius.circular(math.max(0, radius - hairline)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                chrome,
                // The canvas is cut off where the card ends, not squeezed into it.
                Expanded(
                  child: OverflowBox(alignment: Alignment.topCenter, minHeight: 0, maxHeight: double.infinity, child: canvas),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
