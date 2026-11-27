import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../haptics/haptics.dart';
import '../motion/motion.dart';
import '../tokens/theme.dart';

/// What a pressable control is doing, for the styles a stylesheet would hang on `:hover`, `:active`,
/// `:focus-visible` and `:disabled`.
class PressState {
  const PressState({this.hovered = false, this.pressed = false, this.focused = false, this.disabled = false});
  final bool hovered;
  final bool pressed;

  /// Focused from the keyboard: `:focus-visible`, not the focus a tap leaves behind.
  final bool focused;
  final bool disabled;
}

/// The one way a kit control is pressed: tap, Enter and Space, hover and focus for its styles, the press-in scale of
/// `@glacier/motion` (`pressTap`), the mark the haptics listener looks for, and a button's semantics. Every ported
/// component that the web kit built on `<button>` builds on this, so they all press alike.
class GlacierPressable extends StatefulWidget {
  const GlacierPressable({
    super.key,
    required this.onPressed,
    required this.builder,
    this.onLongPress,
    this.haptic = HapticKind.light,
    this.pressScale,
    this.semanticLabel,
    this.button = true,
    this.toggled,
    this.selected,
    this.focusNode,
    this.autofocus = false,
    this.canRequestFocus = true,
    this.behavior = HitTestBehavior.opaque,
    this.onHover,
    this.onFocusChange,
    this.excludeSemantics = false,
  });

  /// Null disables the control.
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final Widget Function(BuildContext context, PressState state) builder;

  /// The feedback a touch gives (`data-haptic`); null is none.
  final HapticKind? haptic;

  /// How far it dips while pressed; null and it does not move.
  final PressScale? pressScale;
  final String? semanticLabel;
  final bool button;

  /// `aria-checked` / `aria-pressed`, where the control has one.
  final bool? toggled;
  final bool? selected;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool canRequestFocus;
  final HitTestBehavior behavior;
  final ValueChanged<bool>? onHover;
  final ValueChanged<bool>? onFocusChange;
  final bool excludeSemantics;

  @override
  State<GlacierPressable> createState() => _GlacierPressableState();
}

class _GlacierPressableState extends State<GlacierPressable> {
  bool _hovered = false, _pressed = false, _focusVisible = false;

  bool get _disabled => widget.onPressed == null;

  void _activate() {
    if (_disabled) return;
    widget.onPressed!();
  }

  void _set(VoidCallback change) {
    if (mounted) setState(change);
  }

  /// Takes a pointer's coming or going. A disabled control tells its listener only of the going.
  void _hover(bool on) {
    if (on == _hovered) return;
    _set(() => _hovered = on);
    if (!_disabled || !on) widget.onHover?.call(on);
  }

  // On a phone's page a finger held on a button is the browser's long press: it asks for a context menu, and no
  // click follows when the finger lifts (a 0.9 s hold on a note's More button opens nothing, and a held row in the
  // sidebar opens no note). The button looks pressed all the while. A mouse's button held is still a click, and a
  // button with a long press of its own has its own recogniser for it.
  static bool get _touch => defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;
  Timer? _hold;
  bool _held = false;

  /// Starts timing a finger's hold: past the long-press time it is marked held, and its lift is no tap.
  void _watchHold() {
    _endHold();
    if (!_touch || widget.onLongPress != null) return;
    _hold = Timer(kLongPressTimeout, () => _held = true);
  }

  void _endHold() {
    _hold?.cancel();
    _hold = null;
    _held = false;
  }

  @override
  void dispose() {
    _hold?.cancel();
    super.dispose();
  }

  /// The gesture's tap: the press, unless the finger was held too long.
  void _tapped() {
    final held = _held;
    _endHold();
    if (!held) _activate();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = GlacierTheme.of(context);
    final state = PressState(hovered: _hovered && !_disabled, pressed: _pressed && !_disabled, focused: _focusVisible && !_disabled, disabled: _disabled);
    Widget child = widget.builder(context, state);
    final dip = widget.pressScale;
    if (dip != null) {
      child = AnimatedScale(
        scale: state.pressed && !tokens.reducedMotion ? dip.scale : 1,
        duration: tokens.duration('glacier-duration-fast'),
        curve: tokens.curve('glacier-ease-out'),
        child: child,
      );
    }
    child = GestureDetector(
      behavior: widget.behavior,
      // The Semantics below carries the tap, and a second one from here would be a second node; a caller that
      // writes its own semantics (a radio in its group) takes the tap from here instead.
      excludeFromSemantics: !widget.excludeSemantics,
      onTapDown: _disabled
          ? null
          : (_) {
              _watchHold();
              _set(() => _pressed = true);
            },
      onTapUp: _disabled ? null : (_) => _set(() => _pressed = false),
      onTapCancel: _disabled
          ? null
          : () {
              _endHold();
              _set(() => _pressed = false);
            },
      onTap: _disabled ? null : _tapped,
      onLongPress: _disabled ? null : widget.onLongPress,
      child: child,
    );
    child = HapticTarget(kind: widget.haptic, enabled: !_disabled, child: child);
    child = FocusableActionDetector(
      enabled: !_disabled && widget.canRequestFocus,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      mouseCursor: _disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _activate()),
      },
      onShowFocusHighlight: (on) => _set(() => _focusVisible = on),
      onFocusChange: widget.onFocusChange,
      child: child,
    );
    // `:hover` is a pointer over the element, whatever was last pressed. The detector above only says so in the
    // keyboard-and-mouse highlight mode, which a phone is not in until a key has been pressed: a mouse on a folding
    // phone's desktop mode, or a trackpad on a tablet, lit nothing. A mouse region hears every pointer that hovers
    // (a finger never does), in either mode.
    child = MouseRegion(
      hitTestBehavior: HitTestBehavior.deferToChild,
      onEnter: (_) => _hover(true),
      onExit: (_) => _hover(false),
      child: child,
    );
    if (widget.excludeSemantics) return child;
    return Semantics(
      button: widget.button,
      enabled: !_disabled,
      label: widget.semanticLabel,
      toggled: widget.toggled,
      selected: widget.selected,
      onTap: _disabled ? null : _activate,
      child: child,
    );
  }
}

/// `outline: 2px solid var(--glacier-focus-ring); outline-offset: 2px` on `:focus-visible`: a ring drawn outside the
/// child's own box, which takes no room in the layout.
class GlacierFocusRing extends StatefulWidget {
  const GlacierFocusRing({super.key, required this.visible, this.radius, this.offset = 2, this.width = 2, this.color, required this.child});

  final bool visible;

  /// The child's own corner radius; the ring's is this plus [offset]. Null is the full pill.
  final double? radius;
  final double offset;
  final double width;

  /// The ring's colour; the focus-ring token unless a rule asks for another (`outline-color: currentColor`).
  final Color? color;
  final Widget child;

  @override
  State<GlacierFocusRing> createState() => _GlacierFocusRingState();
}

class _GlacierFocusRingState extends State<GlacierFocusRing> {
  // The ring is a painter put round the child only while it shows; the key carries the child's state across.
  final GlobalKey _child = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final child = KeyedSubtree(key: _child, child: widget.child);
    if (!widget.visible) return child;
    final color = widget.color ?? GlacierTheme.of(context).color('glacier-focus-ring');
    return CustomPaint(foregroundPainter: _RingPainter(color, widget.radius, widget.offset, widget.width), child: child);
  }
}

/// Strokes the ring [offset] outside the child's box, its corners rounded to match.
class _RingPainter extends CustomPainter {
  _RingPainter(this.color, this.radius, this.offset, this.width);
  final Color color;
  final double? radius;
  final double offset, width;

  @override
  void paint(Canvas canvas, Size size) {
    final grow = offset + width / 2;
    final rect = (Offset.zero & size).inflate(grow);
    final r = radius == null ? rect.shortestSide / 2 : radius! + grow;
    canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(r)), Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..color = color);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.color != color || old.radius != radius || old.offset != offset || old.width != width;
}
