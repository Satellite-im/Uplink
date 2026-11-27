/// The tri toggle a space's permissions are set with, as Discord's channel overrides are (Matt, 2026-11-18: "make it
/// easier to use with tri toggles for permissions and permission hierarchy"): three segments side by side, Deny (✗,
/// red), As the circle says (/, plain) and Allow (✓, green), the chosen one filled.
///
/// Read by a screen reader as one choice of three, each segment a button that says whether it is chosen; on a keyboard
/// each segment takes the focus in turn, Space or Enter chooses it, and the arrow keys move the choice left and right.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../circles/circle.dart';
import '../../kit/semantic_colors.dart';
import '../dialup/bevel.dart';

/// The toggle: shows [value] and tells [onChanged] of the segment pressed or stepped to.
class PermTriToggle extends StatelessWidget {
  const PermTriToggle({super.key, required this.value, required this.onChanged, required this.label, this.disabled = false});

  final PermOverride value;

  /// Told of the segment chosen; null, or [disabled], and it only shows.
  final ValueChanged<PermOverride>? onChanged;

  /// What it sets, for a screen reader: "Write for Moderators".
  final String label;
  final bool disabled;

  bool get _off => disabled || onChanged == null;

  /// Moves the choice one segment along for an arrow key, stopping at either end.
  void _step(int by) {
    if (_off) return;
    final i = (value.index + by).clamp(0, PermOverride.values.length - 1);
    if (i != value.index) onChanged!(PermOverride.values[i]);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    final r = bevel ? 0.0 : t.radius('md');
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Semantics(
      label: label,
      value: value.label,
      container: true,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (node, e) {
          if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
          final k = e.logicalKey;
          if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight) {
            final right = k == LogicalKeyboardKey.arrowRight;
            _step(right != rtl ? 1 : -1);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Opacity(
          opacity: _off ? 0.5 : 1,
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: t.color('app-paper-3'),
              borderRadius: BorderRadius.circular(r + 2),
              border: Border.all(color: t.color('glacier-border-subtle'), width: t.len('glacier-hairline')),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              for (final s in PermOverride.values) _Segment(state: s, chosen: s == value, radius: r, label: '${s.label}, $label', onPressed: _off ? null : () => onChanged!(s)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// One of the three segments: its mark, on its own colour when [chosen] (red, plain or green).
class _Segment extends StatelessWidget {
  const _Segment({required this.state, required this.chosen, required this.radius, required this.label, required this.onPressed});
  final PermOverride state;
  final bool chosen;
  final double radius;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final fill = switch (state) {
      PermOverride.deny => t.danger,
      PermOverride.inherit => t.color('app-paper'),
      PermOverride.allow => t.online,
    };
    final ink = chosen ? (state == PermOverride.inherit ? t.color('app-ink') : const Color(0xFFFFFFFF)) : t.color('app-ink-3');
    return Semantics(
      inMutuallyExclusiveGroup: true,
      selected: chosen,
      child: GlacierPressable(
        key: ValueKey('perm-${state.name}'),
        onPressed: onPressed,
        semanticLabel: label,
        selected: chosen,
        builder: (context, s) => GlacierFocusRing(
          visible: s.focused,
          radius: radius,
          offset: -1,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: 34,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: chosen ? fill : (s.hovered ? t.color('app-paper-2') : const Color(0x00000000)),
              borderRadius: BorderRadius.circular(radius),
            ),
            child: switch (state) {
              PermOverride.deny => AppIcon(Lucide.x, size: 15, strokeWidth: 2.6, wash: false, color: ink),
              PermOverride.allow => AppIcon(Lucide.check, size: 15, strokeWidth: 2.6, wash: false, color: ink),
              PermOverride.inherit => CustomPaint(size: const Size(14, 14), painter: _Slash(ink)),
            },
          ),
        ),
      ),
    );
  }
}

/// The "/" of As the circle says, drawn as the icons beside it are (Lucide has no slash of its own in the app's set).
class _Slash extends CustomPainter {
  const _Slash(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
      Offset(size.width * 0.72, size.height * 0.14),
      Offset(size.width * 0.28, size.height * 0.86),
      Paint()
        ..color = color
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_Slash old) => old.color != color;
}
