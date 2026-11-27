import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

import '../haptics/haptics.dart';
import '../motion/motion.dart';
import '../tokens/theme.dart';
import '../tokens/overrides.dart';
import '../tokens/tokens.dart';
import 'css_effects.dart';
import 'pressable.dart';

/// `size` of a [GlacierSwitch]: 44 x 26 (`md`) or 36 x 20 (`sm`) at a 16px root.
enum GlacierSwitchSize { sm, md }

/// Thumb travel in px per size: track width - thumb - both padding edges (`TRAVEL` in Switch.tsx).
const _travel = {GlacierSwitchSize.sm: 16.0, GlacierSwitchSize.md: 18.0};

/// The inset highlight both the thumb and a glass track carry.
const _highlight = 'inset 0 var(--glacier-hairline) 0 var(--glacier-glass-highlight)';

/// Port of `@glacier/react`'s `Switch` (`atoms/inputs/Selection/Switch.tsx`, with the `.control`, `.track`, `.thumb`
/// and `.glass` rules of `Selection.module.css`).
///
/// Controlled with [checked] and [onCheckedChange], or uncontrolled from [defaultChecked]. The thumb travels on the
/// `Spring.snappy` spring and keeps its velocity when it is turned round mid-flight, as a framer-motion value does;
/// under reduced motion it jumps. The whole control, label included, is the press target.
///
/// What differs from the React original:
/// - `skeleton` is not ported.
/// - Enter toggles it as well as Space ([GlacierPressable] gives every control both); a native checkbox takes Space
///   alone.
/// - The thumb's travel follows the text direction. On the page the travel is a physical `translateX`, which carries
///   the thumb out of the track in a right-to-left layout.
/// - A disabled switch shows the plain cursor, not `not-allowed`.
/// - [thumbColor] is an addition, for an app stylesheet that repaints the thumb (ink.css
///   `[role='switch'] + span > span`).
class GlacierSwitch extends StatefulWidget {
  const GlacierSwitch({
    super.key,
    this.label,
    this.checked,
    this.defaultChecked = false,
    this.onCheckedChange,
    this.disabled = false,
    this.size = GlacierSwitchSize.md,
    this.glass = false,
    this.ariaLabel,
    this.focusNode,
    this.autofocus = false,
    this.thumbColor,
  });

  /// What the switch turns on, set after the track in the kit's small text. It names the switch to a screen reader.
  final Widget? label;

  /// The state, where the parent holds it. Null and the switch holds its own, starting from [defaultChecked].
  final bool? checked;
  final bool defaultChecked;
  final ValueChanged<bool>? onCheckedChange;
  final bool disabled;
  final GlacierSwitchSize size;

  /// Renders the frosted glass material on the track instead of a solid surface. A checked track is the accent
  /// either way, as the stylesheet's cascade has it.
  final bool glass;

  /// `aria-label`: the switch's name where it has no [label].
  final String? ariaLabel;
  final FocusNode? focusNode;
  final bool autofocus;

  /// The thumb's fill. Null is the kit's own `oklch(0.995 0 0)`.
  final Color? thumbColor;

  @override
  State<GlacierSwitch> createState() => _GlacierSwitchState();
}

class _GlacierSwitchState extends State<GlacierSwitch> with SingleTickerProviderStateMixin {
  /// The state where the switch keeps its own (no `checked` given); the thumb's offset from its off place, in
  /// logical pixels, on a spring; and where that spring was last sent.
  late bool _internal = widget.defaultChecked;
  late final AnimationController _x;
  late double _target;

  bool get _checked => widget.checked ?? _internal;
  double get _rest => _checked ? _travel[widget.size]! : 0;

  @override
  void initState() {
    super.initState();
    // `initial={false}`: it starts where it rests.
    _target = _rest;
    _x = AnimationController.unbounded(vsync: this, value: _target);
  }

  @override
  void didUpdateWidget(GlacierSwitch old) {
    super.didUpdateWidget(old);
    _settle();
  }

  @override
  void dispose() {
    _x.dispose();
    super.dispose();
  }

  /// Sends the thumb to where the state now puts it.
  void _settle() {
    final to = _rest;
    if (to == _target) return;
    _target = to;
    if (GlacierTheme.of(context).reducedMotion) {
      _x.value = to;
      return;
    }
    // framer-motion's own rest thresholds for a value measured in pixels: within half a pixel and under 2px/s.
    _x.animateWith(SpringSimulation(
      springDescription(Spring.snappy),
      _x.value,
      to,
      _x.velocity,
      snapToEnd: true,
      tolerance: const Tolerance(distance: 0.5, velocity: 2),
    ));
  }

  /// Flips the switch: its own state where it keeps one, and the listener told either way.
  void _toggle() {
    final next = !_checked;
    if (widget.checked == null) setState(() => _internal = next);
    widget.onCheckedChange?.call(next);
    _settle();
  }

  /// `.control`'s text: the sans face at the small step, in the text colour, on the font's own line height.
  static TextStyle _labelStyle(Tokens t) {
    final sm = t.text('sm');
    return TextStyle(
      fontFamily: sm.fontFamily,
      fontFamilyFallback: sm.fontFamilyFallback,
      fontSize: sm.fontSize,
      fontWeight: sm.fontWeight,
      fontVariations: sm.fontVariations,
      letterSpacing: sm.letterSpacing,
      color: sm.color,
      decoration: TextDecoration.none,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = GlacierTheme.of(context);
    final small = widget.size == GlacierSwitchSize.sm;
    final checked = _checked;
    final rtl = Directionality.maybeOf(context) == TextDirection.rtl;
    final full = t.radius('full');
    final thumbSize = t.lenOf(small ? '1rem' : '1.375rem');
    final thumbShadows = cssShadowsOf(t, '$_highlight, var(--glacier-shadow-2)');

    final Widget thumb = AnimatedBuilder(
      animation: _x,
      builder: (context, child) => Transform.translate(offset: Offset(rtl ? -_x.value : _x.value, 0), child: child),
      child: SizedBox(
        width: thumbSize,
        height: thumbSize,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: widget.thumbColor ?? GlacierOverrides.maybeOf(context)?.switchThumbColor?.call(t) ?? t.colorOf('oklch(0.995 0 0)'),
            borderRadius: BorderRadius.circular(full),
            boxShadow: thumbShadows.outer,
          ),
          child: GlacierInsetShadows(shadows: thumbShadows, radius: full),
        ),
      ),
    );

    // `.track[data-checked]` outranks `.glass`, so glass shows on the unchecked track alone.
    final trackColor = checked ? t.color('glacier-accent-solid') : t.color(widget.glass ? 'glacier-glass-regular' : 'glacier-border');
    final Widget track = GlacierBackdrop(
      radius: full,
      enabled: widget.glass,
      child: AnimatedContainer(
        duration: t.duration('glacier-duration-fast'),
        curve: t.curve('glacier-ease-out'),
        width: t.lenOf(small ? '2.25rem' : '2.75rem'),
        height: t.lenOf(small ? '1.25rem' : '1.625rem'),
        decoration: BoxDecoration(color: trackColor, borderRadius: BorderRadius.circular(full)),
        child: GlacierInsetShadows(
          shadows: widget.glass ? cssShadowsOf(t, _highlight) : const [],
          radius: full,
          child: Padding(
            padding: EdgeInsets.all(t.lenOf('0.125rem')),
            child: Align(alignment: AlignmentDirectional.centerStart, child: thumb),
          ),
        ),
      ),
    );

    return MergeSemantics(
      child: Opacity(
        opacity: widget.disabled ? 0.5 : 1,
        child: GlacierPressable(
          onPressed: widget.disabled ? null : _toggle,
          haptic: HapticKind.selection,
          button: false,
          toggled: checked,
          semanticLabel: widget.ariaLabel,
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          builder: (context, state) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GlacierFocusRing(visible: state.focused, child: track),
              if (widget.label != null) ...[
                SizedBox(width: t.space(2)),
                Flexible(child: DefaultTextStyle(style: _labelStyle(t), child: widget.label!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
