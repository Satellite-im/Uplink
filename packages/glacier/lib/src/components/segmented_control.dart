import 'dart:ui' show SemanticsRole;

import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../haptics/haptics.dart';
import '../motion/motion.dart';
import '../tokens/theme.dart';
import '../tokens/overrides.dart';
import 'css_effects.dart';
import 'pressable.dart';

/// `size` of a [GlacierSegmentedControl]: the kit's `ControlSize`, so its track lines up with a button or a field of
/// the same size.
enum GlacierSegmentedSize { sm, md, lg }

/// One segment (`SegmentedOption`).
class GlacierSegmentedOption {
  const GlacierSegmentedOption({required this.value, required this.label, this.disabled = false});

  final String value;

  /// What the segment shows, set in the control's own text: usually a [Text], or a row of an icon and one.
  final Widget label;
  final bool disabled;
}

/// Port of `@glacier/react`'s `SegmentedControl` (`molecules/Segmented/SegmentedControl.tsx`, with
/// `Segmented.module.css`): a segmented toggle whose selected thumb springs between segments instead of jumping.
///
/// Every segment is as wide as the widest label, or an equal share of the row under [fullWidth]. Controlled with
/// [value] and [onValueChange], or uncontrolled from [defaultValue], which falls back to the first option that is not
/// disabled. The thumb moves as framer-motion's shared layout element does: from wherever it is drawn to the new
/// segment on the [spring], starting from rest each time; under reduced motion it jumps. Arrow keys move the
/// selection and the focus with it, round the ends and past disabled options, and Tab stops once, on the selection.
///
/// What differs from the React original:
/// - `skeleton` is not ported.
/// - Enter selects the focused segment as well as Space ([GlacierPressable] gives every control both).
/// - Left and right arrows follow the text direction.
/// - A label is one widget: the stylesheet's `gap` between an icon and its text is the caller's to set in a row.
/// - The press-in dip is skipped under reduced motion, as [GlacierPressable] does for every control.
/// - `backdrop-filter` is only applied while the track colour is see-through, since behind an opaque one it shows
///   nothing.
/// - [selectedLabelColor] and [thumbShadow] are additions, for an app stylesheet that restyles those parts (ink.css
///   `[role='radiogroup'] > label[data-selected] > span:last-child` and
///   `[role='radiogroup'] > label > span[aria-hidden='true']`).
class GlacierSegmentedControl extends StatefulWidget {
  const GlacierSegmentedControl({
    super.key,
    required this.options,
    this.value,
    this.defaultValue,
    this.onValueChange,
    this.size = GlacierSegmentedSize.md,
    this.fullWidth = false,
    this.spring = Spring.snappy,
    this.disabled = false,
    this.ariaLabel,
    this.selectedLabelColor,
    this.thumbShadow,
  });

  final List<GlacierSegmentedOption> options;

  /// The selected option's value, where the parent holds it. Null and the control holds its own.
  final String? value;
  final String? defaultValue;
  final ValueChanged<String>? onValueChange;
  final GlacierSegmentedSize size;

  /// Stretches the control over the row, in equal segments that may be narrower than their labels.
  final bool fullWidth;

  /// Spring preset for the thumb.
  final Spring spring;
  final bool disabled;

  /// `aria-label`: the accessible name for the group.
  final String? ariaLabel;

  /// The selected segment's label colour, whether or not it is disabled. Null is the kit's own: `--glacier-text`,
  /// or `--glacier-text-disabled` on a disabled segment.
  final Color? selectedLabelColor;

  /// The thumb's shadow. Null is the kit's own: `--glacier-shadow-2` under an inset hairline highlight. An empty
  /// list is `box-shadow: none`.
  final List<BoxShadow>? thumbShadow;

  @override
  State<GlacierSegmentedControl> createState() => _GlacierSegmentedControlState();
}

class _GlacierSegmentedControlState extends State<GlacierSegmentedControl> with SingleTickerProviderStateMixin {
  /// The selected value where the control holds its own (no `value` given).
  late String _internal;

  /// How far the thumb has come on its way from [_from] to [_to], 0 to 1, and a little past on the spring's overshoot.
  late final AnimationController _move;

  /// Where the thumb set out from and where it is going, in segments from the start.
  double _from = 0, _to = 0;

  /// The segment the thumb was last sent to, or null where nothing is selected and there is no thumb.
  int? _shown;
  final List<FocusNode> _nodes = [];

  String get _selected => widget.value ?? _internal;
  int get _selectedIndex => widget.options.indexWhere((o) => o.value == _selected);
  double get _position => _from + (_to - _from) * _move.value;

  bool _isDisabled(int index) => widget.disabled || widget.options[index].disabled;

  @override
  void initState() {
    super.initState();
    _internal = widget.defaultValue ?? widget.options.where((o) => !o.disabled).firstOrNull?.value ?? '';
    _move = AnimationController.unbounded(vsync: this, value: 1);
    final index = _selectedIndex;
    _shown = index < 0 ? null : index;
    _from = _to = index < 0 ? 0 : index.toDouble();
    _syncNodes();
  }

  @override
  void didUpdateWidget(GlacierSegmentedControl old) {
    super.didUpdateWidget(old);
    _syncNodes();
    _syncThumb();
  }

  @override
  void dispose() {
    _move.dispose();
    for (final node in _nodes) {
      node.dispose();
    }
    super.dispose();
  }

  /// One focus node a segment, with the arrow keys on it; and one Tab stop for the group, as radios of one name have.
  void _syncNodes() {
    while (_nodes.length > widget.options.length) {
      _nodes.removeLast().dispose();
    }
    while (_nodes.length < widget.options.length) {
      final index = _nodes.length;
      _nodes.add(FocusNode(debugLabel: 'segment $index', onKeyEvent: (node, event) => _onKey(index, event)));
    }
    final selected = _selectedIndex;
    var stop = selected >= 0 && !_isDisabled(selected) ? selected : -1;
    if (stop < 0) {
      for (var i = 0; i < widget.options.length && stop < 0; i++) {
        if (!_isDisabled(i)) stop = i;
      }
    }
    for (var i = 0; i < _nodes.length; i++) {
      _nodes[i].skipTraversal = i != stop;
    }
  }

  /// Sends the thumb to the selected segment, from wherever it is drawn now.
  void _syncThumb() {
    final index = _selectedIndex;
    final next = index < 0 ? null : index;
    if (next == _shown) return;
    final had = _shown;
    _shown = next;
    _move.stop();
    if (next == null) return;
    // A thumb that has just appeared has nowhere to come from.
    if (had == null || GlacierTheme.of(context).reducedMotion) {
      _from = _to = next.toDouble();
      _move.value = 1;
      return;
    }
    _from = _position;
    _to = next.toDouble();
    _move.value = 0;
    // A layout animation runs its spring over 0 to 1000 from rest, and framer-motion calls a spring done within
    // 0.5 of its end and under 2 a second: the same thresholds, on 0 to 1.
    _move.animateWith(SpringSimulation(
      springDescription(widget.spring),
      0,
      1,
      0,
      snapToEnd: true,
      tolerance: const Tolerance(distance: 0.0005, velocity: 0.002),
    ));
  }

  /// Selects a segment by a press or a key: the control's own state where it holds it, and the listener told.
  void _select(int index) {
    final value = widget.options[index].value;
    if (value == _selected) return; // a radio that is already checked does not change
    if (widget.value == null) setState(() => _internal = value);
    widget.onValueChange?.call(value);
    _syncNodes();
    _syncThumb();
  }

  /// The arrow keys on a focused segment: selects and focuses the next enabled one that way, round the ends, as
  /// a radio group does. Left and right swap in a right-to-left layout.
  KeyEventResult _onKey(int index, KeyEvent event) {
    if (event is KeyUpEvent || index >= widget.options.length) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final rtl = Directionality.maybeOf(context) == TextDirection.rtl;
    final int step;
    if (key == LogicalKeyboardKey.arrowDown || key == (rtl ? LogicalKeyboardKey.arrowLeft : LogicalKeyboardKey.arrowRight)) {
      step = 1;
    } else if (key == LogicalKeyboardKey.arrowUp || key == (rtl ? LogicalKeyboardKey.arrowRight : LogicalKeyboardKey.arrowLeft)) {
      step = -1;
    } else {
      return KeyEventResult.ignored;
    }
    final count = widget.options.length;
    for (var k = 1; k < count; k++) {
      final next = ((index + step * k) % count + count) % count;
      if (_isDisabled(next)) continue;
      _select(next);
      _nodes[next].requestFocus();
      break;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final t = GlacierTheme.of(context);
    final size = widget.size.name;
    final (padding, font) = switch (widget.size) {
      GlacierSegmentedSize.sm => (t.space(3), 'xs'),
      GlacierSegmentedSize.md => (t.space(4), 'sm'),
      GlacierSegmentedSize.lg => (t.space(5), 'md'),
    };
    // Track height = control height, so mixed rows line up: the segment gives back the track's own padding.
    final segmentHeight = t.lenOf('calc(var(--glacier-control-height-$size) - 0.375rem)');
    final radius = t.len('glacier-control-radius');
    final hairline = t.len('glacier-hairline');
    final trackColor = t.color('glacier-segment-track');
    final fast = t.duration('glacier-duration-fast');
    final easeOut = t.curve('glacier-ease-out');
    final count = widget.options.length;
    final selected = _selectedIndex;

    final thumbShadows = cssShadowsOf(t, 'inset 0 var(--glacier-hairline) 0 var(--glacier-glass-highlight), var(--glacier-shadow-2)');
    final overrides = GlacierOverrides.maybeOf(context);
    final ownShadow = widget.thumbShadow ?? overrides?.segmentedThumbShadow?.call(t);
    final Widget thumb = DecoratedBox(
      decoration: BoxDecoration(
        color: t.color('glacier-segment-thumb'),
        borderRadius: BorderRadius.circular(radius),
        boxShadow: ownShadow ?? thumbShadows.outer,
      ),
      child: GlacierInsetShadows(shadows: ownShadow == null ? thumbShadows : const [], radius: radius),
    );

    // An app's own segments (GlacierOverrides.segmentedSegment): no track and no thumb, each segment as tall as the
    // control, drawn by the app.
    final drawn = overrides?.segmentedSegment;
    final fullHeight = t.len('glacier-control-height-$size');

    Widget segment(int index) {
      final option = widget.options[index];
      final isSelected = index == selected;
      final isDisabled = _isDisabled(index);
      if (drawn != null) {
        return Semantics(
          container: true,
          inMutuallyExclusiveGroup: true,
          checked: isSelected,
          enabled: !isDisabled,
          child: GlacierPressable(
            onPressed: isDisabled ? null : () => _select(index),
            haptic: HapticKind.selection,
            focusNode: _nodes[index],
            excludeSemantics: true,
            builder: (context, state) => SizedBox(
              height: fullHeight,
              child: drawn(
                context,
                GlacierSegmentLook(
                  label: option.label,
                  style: t.text(font, weight: isSelected ? 'semibold' : 'medium').copyWith(height: 1),
                  padding: padding,
                  selected: isSelected,
                  pressed: state.pressed,
                  hovered: state.hovered,
                  focused: state.focused,
                  disabled: isDisabled,
                ),
              ),
            ),
          ),
        );
      }
      // `.segment.disabled .label` comes after `.segment[data-selected] .label` at the same weight, so it wins.
      final kitColor = t.color(isDisabled ? 'glacier-text-disabled' : (isSelected ? 'glacier-text' : 'glacier-text-muted'));
      final color = isSelected ? (widget.selectedLabelColor ?? overrides?.segmentedSelectedLabelColor?.call(t) ?? kitColor) : kitColor;
      final style = t.text(font, weight: isSelected ? 'semibold' : 'medium').copyWith(height: 1);
      return Semantics(
        container: true,
        inMutuallyExclusiveGroup: true,
        checked: isSelected,
        enabled: !isDisabled,
        // The tap and the focus come up from the pressable's own detectors into this node; a second `onTap` here would
        // split the radio in two.
        child: GlacierPressable(
          onPressed: isDisabled ? null : () => _select(index),
          haptic: HapticKind.selection,
          pressScale: PressScale.chip,
          focusNode: _nodes[index],
          excludeSemantics: true,
          builder: (context, state) => SizedBox(
            height: segmentHeight,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: padding),
              child: Center(
                // `.label::after`: a ring a space-1 out from the label, with its outline another pixel out.
                child: GlacierFocusRing(
                  visible: state.focused,
                  radius: radius,
                  offset: t.space(1) + 1,
                  // `white-space: nowrap`, and never narrower than its words: in a segment too narrow for it (which
                  // only `fullWidth` can make) the label runs out over both edges, as a centred flex item does.
                  child: OverflowBox(
                    minWidth: 0,
                    maxWidth: double.infinity,
                    fit: OverflowBoxFit.deferToChild,
                    child: TweenAnimationBuilder<Color?>(
                      tween: ColorTween(end: color),
                      duration: fast,
                      curve: easeOut,
                      builder: (context, shade, child) => DefaultTextStyle(
                        style: style.copyWith(color: shade),
                        softWrap: false,
                        overflow: TextOverflow.visible,
                        child: IconTheme.merge(data: IconThemeData(color: shade), child: child!),
                      ),
                      child: option.label,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    Widget root = drawn != null
        ? Row(children: [for (var i = 0; i < count; i++) Expanded(child: segment(i))])
        : DecoratedBox(
      decoration: BoxDecoration(
        color: trackColor,
        border: Border.all(color: t.color('glacier-glass-border'), width: hairline),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Padding(
        padding: EdgeInsets.all(hairline + t.lenOf('0.1875rem')),
        child: Stack(
          fit: StackFit.passthrough,
          alignment: Alignment.topLeft,
          children: [
            if (_shown != null && selected >= 0)
              Positioned.fill(
                child: ExcludeSemantics(
                  child: AnimatedBuilder(
                    animation: _move,
                    builder: (context, child) {
                      // The thumb is one segment wide, so the room it moves over is count - 1 segments.
                      final along = count > 1 ? _position / (count - 1) : 0.0;
                      return Align(alignment: AlignmentDirectional(along * 2 - 1, 0), child: child);
                    },
                    child: FractionallySizedBox(widthFactor: 1 / count, heightFactor: 1, child: thumb),
                  ),
                ),
              ),
            Row(children: [for (var i = 0; i < count; i++) Expanded(child: segment(i))]),
          ],
        ),
      ),
    );
    // The track's blur shows only through a see-through track colour.
    if (drawn == null) root = GlacierBackdrop(radius: radius, enabled: trackColor.a < 1, child: root);
    // An inline grid of equal columns, each as wide as the widest label asks for. Such a grid has no narrower size
    // to fall back to, so in a row too narrow for it it runs out past the end rather than squeezing its labels.
    root = widget.fullWidth
        ? SizedBox(width: double.infinity, child: root)
        : OverflowBox(
            minWidth: 0,
            maxWidth: double.infinity,
            alignment: AlignmentDirectional.centerStart,
            fit: OverflowBoxFit.deferToChild,
            child: IntrinsicWidth(child: root),
          );

    return Semantics(
      container: true,
      explicitChildNodes: true,
      role: SemanticsRole.radioGroup,
      label: widget.ariaLabel,
      child: root,
    );
  }
}
