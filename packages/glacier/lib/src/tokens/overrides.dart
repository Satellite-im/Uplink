import 'package:flutter/widgets.dart';

import 'tokens.dart';

/// What an app's own stylesheet does to the kit's parts by selector, for a whole subtree.
///
/// Most of an app's restyling arrives through the tokens. The rest is rules that reach into a component
/// (`[role='switch'] + span > span { background: var(--app-paper) }`), which no token carries. Each is a function of
/// the tokens here, so it follows the theme; a component uses its own parameter first, then this, then the kit's.
class GlacierOverrides extends InheritedWidget {
  const GlacierOverrides({super.key, this.switchThumbColor, this.segmentedSelectedLabelColor, this.segmentedThumbShadow, this.segmentedSegment, required super.child});

  /// The switch's thumb.
  final Color Function(Tokens tokens)? switchThumbColor;

  /// The label of a segmented control's selected option.
  final Color Function(Tokens tokens)? segmentedSelectedLabelColor;

  /// The shadows of a segmented control's thumb, outer and inset together; an empty list is `box-shadow: none`.
  final List<BoxShadow> Function(Tokens tokens)? segmentedThumbShadow;

  /// Draws each segment of a segmented control itself, in place of the kit's track and sliding thumb: for a look
  /// whose toggles are a row of separate buttons (an app's retro look, where the chosen one is a button held in).
  /// The kit keeps the pressing, focus, keys and semantics, and sizes each segment to the control's full height.
  /// Null is the kit's own drawing.
  final Widget Function(BuildContext context, GlacierSegmentLook segment)? segmentedSegment;

  static GlacierOverrides? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<GlacierOverrides>();

  @override
  bool updateShouldNotify(GlacierOverrides old) =>
      old.switchThumbColor != switchThumbColor || old.segmentedSelectedLabelColor != segmentedSelectedLabelColor || old.segmentedThumbShadow != segmentedThumbShadow || old.segmentedSegment != segmentedSegment;
}

/// One segment as [GlacierOverrides.segmentedSegment] is asked to draw it.
class GlacierSegmentLook {
  const GlacierSegmentLook({
    required this.label,
    required this.style,
    required this.padding,
    required this.selected,
    required this.pressed,
    required this.hovered,
    required this.focused,
    required this.disabled,
  });

  /// The option's own label, not yet coloured.
  final Widget label;

  /// The kit's text for the label at this size and state, without a colour.
  final TextStyle style;

  /// The kit's room either side of the label.
  final double padding;
  final bool selected, pressed, hovered, focused, disabled;
}
