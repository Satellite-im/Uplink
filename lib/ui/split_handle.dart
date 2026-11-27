import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../app_state.dart';

/// Where two panes meet, a handle to drag the line between them (Matt, 2026-11-17: "on desktop and unfolded mobile add
/// a handle to resize the sidebar and the main chat page and any other split pane views like claude has"): invisible
/// until the pointer is over it, then a short grip in the accent and the column-resize cursor (only the grip, not the
/// whole line); on a touch screen the grip stays, so there is something to put a finger on. A double click or a double tap puts the
/// width back as it was made. What it was dragged to is kept with the device's choices ([PaneWidth]).
class SplitHandle extends StatefulWidget {
  const SplitHandle({super.key, required this.onDrag, this.onDone, this.onReset, this.label = 'Resize', this.vertical = false});

  /// The pointer moved this far across while held (down, for a [vertical] one).
  final ValueChanged<double> onDrag;

  /// A line across the page, between a pane above and one below: dragged up and down (a space's call over its chat,
  /// SpaceSplit).
  final bool vertical;

  /// Let go: the width to keep.
  final VoidCallback? onDone;

  /// Double clicked: the width as it was made.
  final VoidCallback? onReset;
  final String label;

  /// How wide the handle is to the pointer, across the line: a mouse's, and a finger's.
  static const double mouseWidth = 9;
  static const double touchWidth = 22;

  /// The handle's width here: the finger's anywhere but on a computer.
  static double widthOf(BuildContext context) => _touch(context) ? touchWidth : mouseWidth;

  static bool _touch(BuildContext context) => context.tokens.attrs['platform'] != 'desktop';

  @override
  State<SplitHandle> createState() => _SplitHandleState();
}

class _SplitHandleState extends State<SplitHandle> {
  bool _over = false;
  bool _held = false;

  /// Where the pointer was last, along the way the handle moves.
  double? _lastX;

  void _start(bool touch) {
    setState(() => _held = true);
    if (touch) HapticFeedback.selectionClick();
  }

  void _move(double x, double delta) {
    widget.onDrag(x - (_lastX ?? x - delta));
    _lastX = x;
  }

  void _end() {
    setState(() => _held = false);
    widget.onDone?.call();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final touch = SplitHandle._touch(context);
    final lit = _over || _held;
    return Semantics(
      label: widget.label,
      hint: widget.vertical ? 'Drag up or down to resize. Double tap to put it back.' : 'Drag across to resize. Double tap to put it back.',
      child: MouseRegion(
        cursor: widget.vertical ? SystemMouseCursors.resizeRow : SystemMouseCursors.resizeColumn,
        onEnter: (_) => setState(() => _over = true),
        onExit: (_) => setState(() => _over = false),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          dragStartBehavior: DragStartBehavior.down,
          // Measured from where the press began, so the line stays under the pointer: the first few pixels, before
          // the move counts as a drag, are not lost.
          onHorizontalDragDown: widget.vertical ? null : (d) => _lastX = d.globalPosition.dx,
          onHorizontalDragStart: widget.vertical ? null : (_) => _start(touch),
          onHorizontalDragUpdate: widget.vertical ? null : (d) => _move(d.globalPosition.dx, d.delta.dx),
          onHorizontalDragEnd: widget.vertical ? null : (_) => _end(),
          onHorizontalDragCancel: widget.vertical ? null : () => setState(() => _held = false),
          onVerticalDragDown: !widget.vertical ? null : (d) => _lastX = d.globalPosition.dy,
          onVerticalDragStart: !widget.vertical ? null : (_) => _start(touch),
          onVerticalDragUpdate: !widget.vertical ? null : (d) => _move(d.globalPosition.dy, d.delta.dy),
          onVerticalDragEnd: !widget.vertical ? null : (_) => _end(),
          onVerticalDragCancel: !widget.vertical ? null : () => setState(() => _held = false),
          onDoubleTap: widget.onReset,
          // Only the grip lights, never the whole length of the line (Matt, 2026-11-17: "only highlight the handle on
          // the vertical resize handle on the side of the sidebar and other places don't show the whole horizontal
          // line"): with a mouse it shows while the pointer is over the handle or it is held; on a touch screen it is
          // always there, so there is something to put a finger on.
          child: Center(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 120),
              opacity: touch || lit ? 1 : 0,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: widget.vertical ? 36 : (touch ? 6 : 4),
                height: widget.vertical ? (touch ? 6 : 4) : 36,
                decoration: BoxDecoration(
                  color: lit ? t.color('app-accent').withValues(alpha: _held ? 1 : 0.8) : t.color('app-ink-4'),
                  borderRadius: BorderRadius.circular(3),
                  border: touch ? Border.all(color: t.color('glacier-bg'), width: 1.5) : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A pane's width as the person dragged it, kept with the device's choices under `pane_width_<id>`; null until they do.
class PaneWidth {
  PaneWidth._();

  static double? of(AppState app, String id) => double.tryParse(app.choice('pane_width_$id', ''));

  static void keep(AppState app, String id, double? width) => app.set('pane_width_$id', width == null ? '' : width.toStringAsFixed(0));
}
