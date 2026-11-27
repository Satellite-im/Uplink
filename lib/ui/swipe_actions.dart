import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../kit/settings_type.dart';
import '../kit/semantic_colors.dart';

/// What a row dragged sideways has come to.
enum SwipeStage { none, archive, delete, pin }

/// A row of the list that is dragged sideways to act on it (Matt, 2026-11-14: "add swiping to archive, further drag
/// to delete, drag the other direction to pin, add haptic detents for each").
///
/// Dragged to the left it uncovers Archive; dragged further, Delete; dragged to the right, Pin. Each is a detent:
/// the phone ticks as the row passes into one (a firmer knock for Delete) and ticks lightly as it passes back out,
/// so the hand knows what letting go will do without the eye having to read it. Letting go does what the row had
/// come to, and the row slides back. Deleting still asks first: that is the caller's to do in [onDelete].
class SwipeActions extends StatefulWidget {
  const SwipeActions({
    super.key,
    required this.child,
    required this.onArchive,
    required this.onDelete,
    required this.onPin,
    this.archiveLabel = 'Archive',
    this.archiveIcon = Lucide.archive,
    this.pinLabel = 'Pin',
    this.pinIcon = Lucide.pin,
    this.enabled = true,
    this.card,
  });

  final Widget child;
  final VoidCallback onArchive;
  final VoidCallback onDelete;
  final VoidCallback onPin;

  /// What the first detent says and shows: "Unarchive" on the archive's own page.
  final String archiveLabel;
  final LucideIcon archiveIcon;

  /// What the other way says and shows: "Unpin" for a conversation that is pinned.
  final String pinLabel;
  final LucideIcon pinIcon;

  /// Off while several conversations are being chosen: a row is then a thing to tick, not to drag.
  final bool enabled;

  /// The card the row is drawn as: how far it stands in from the row's edges, and how round its corners are. Given
  /// one, what a drag uncovers is drawn inside the card's own outline and the card's face slides within it (Matt,
  /// 2026-11-15: "make the pin unpin delete and archive within the card instead of being on the left and right").
  /// Without one it is drawn across the whole row.
  final ({EdgeInsets inset, double radius})? card;

  /// How far a row is dragged, in logical pixels, to reach each detent.
  static const archiveAt = 76.0;
  static const pinAt = 76.0;
  static double deleteAt(double width) => math.max(208.0, width * 0.58);

  /// What a row dragged by [dx] (to the left is less than nothing) in a list [width] wide has come to.
  static SwipeStage stageFor(double dx, double width) {
    if (dx <= -deleteAt(width)) return SwipeStage.delete;
    if (dx <= -archiveAt) return SwipeStage.archive;
    if (dx >= pinAt) return SwipeStage.pin;
    return SwipeStage.none;
  }

  @override
  State<SwipeActions> createState() => _SwipeActionsState();
}

class _SwipeActionsState extends State<SwipeActions> with SingleTickerProviderStateMixin {
  late final AnimationController _back = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  /// How far the finger has gone, and how far the row has followed: the same, but that past Pin the row follows
  /// at less than half the pace, so the pull goes slack where there is nothing further to come to.
  double _pulled = 0;
  double _dx = 0;
  double _from = 0;
  double _width = 0;
  SwipeStage _stage = SwipeStage.none;

  @override
  void initState() {
    super.initState();
    _back.addListener(() => setState(() => _dx = _from * (1 - Curves.easeOutCubic.transform(_back.value))));
  }

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  /// The finger moved: the row follows it, and crossing into another stage is felt.
  void _drag(DragUpdateDetails d) {
    // To the left as far as the row is wide; to the right only a little past Pin, with the pull going slack.
    _pulled = (_pulled + (d.primaryDelta ?? 0)).clamp(-_width, SwipeActions.pinAt * 3);
    final next = _pulled <= SwipeActions.pinAt ? _pulled : SwipeActions.pinAt + (_pulled - SwipeActions.pinAt) * 0.45;
    final stage = SwipeActions.stageFor(next, _width);
    if (stage != _stage) {
      // The detents: a knock for Delete, a tick for Archive and Pin, a lighter one on the way back out.
      switch (stage) {
        case SwipeStage.delete:
          HapticFeedback.heavyImpact();
        case SwipeStage.archive || SwipeStage.pin:
          HapticFeedback.mediumImpact();
        case SwipeStage.none:
          HapticFeedback.selectionClick();
      }
    }
    setState(() {
      _dx = next;
      _stage = stage;
    });
  }

  /// Let go: the row springs back, and the stage it was let go in is done.
  void _letGo([DragEndDetails? _]) {
    final stage = _stage;
    _from = _dx;
    _pulled = 0;
    _stage = SwipeStage.none;
    _back.forward(from: 0);
    switch (stage) {
      case SwipeStage.archive:
        widget.onArchive();
      case SwipeStage.delete:
        widget.onDelete();
      case SwipeStage.pin:
        widget.onPin();
      case SwipeStage.none:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final t = context.tokens;
    return LayoutBuilder(builder: (context, box) {
      _width = box.maxWidth;
      final left = _dx < 0;
      final armed = _stage != SwipeStage.none;
      final (ground, ink, icon, label) = switch (_stage) {
        SwipeStage.delete => (t.danger, const Color(0xFFFFFFFF), Lucide.trash2, 'Delete'),
        SwipeStage.archive => (t.info, const Color(0xFFFFFFFF), widget.archiveIcon, widget.archiveLabel),
        SwipeStage.pin => (t.pinned, const Color(0xFFFFFFFF), widget.pinIcon, widget.pinLabel),
        // Not yet come to anything: what it is on the way to, quietly.
        SwipeStage.none => (t.color('app-paper-3'), t.color('app-ink-2'), left ? widget.archiveIcon : widget.pinIcon, left ? widget.archiveLabel : widget.pinLabel),
      };
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) {
          // Taken hold of again while sliding back: it goes on from where it is.
          _back.stop();
          _pulled = _dx <= SwipeActions.pinAt ? _dx : SwipeActions.pinAt + (_dx - SwipeActions.pinAt) / 0.45;
        },
        onHorizontalDragUpdate: _drag,
        onHorizontalDragEnd: _letGo,
        onHorizontalDragCancel: _letGo,
        child: _clip(
          child: Stack(children: [
            if (_dx != 0)
              Positioned.fill(
                child: _inCard(AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  color: ground,
                  alignment: left ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
                  padding: EdgeInsets.symmetric(horizontal: t.space(5)),
                  child: AnimatedScale(
                    scale: armed ? 1.12 : 1,
                    duration: const Duration(milliseconds: 120),
                    // The word joins the picture once enough is uncovered to hold it whole.
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (!left) AppIcon(icon, size: 20, color: ink),
                      if (_dx.abs() > 136) ...[
                        if (!left) SizedBox(width: t.space(2)),
                        Text(label, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: ink)),
                        if (left) SizedBox(width: t.space(2)),
                      ],
                      if (left) AppIcon(icon, size: 20, color: ink),
                    ]),
                  ),
                )),
              ),
            Transform.translate(
              offset: Offset(_dx, 0),
              // The row is solid while it is off its place, so what it uncovers does not show through it.
              // In a card the face is solid of itself, and the room round it shows the action, not the page.
              child: _dx == 0 || widget.card != null ? widget.child : ColoredBox(color: t.color('glacier-bg'), child: widget.child),
            ),
          ]),
        ),
      );
    });
  }

  /// The whole row's edges, or the card's outline while it is off its place (at rest nothing is cut, so the
  /// chosen card's line round it is whole).
  Widget _clip({required Widget child}) {
    final card = widget.card;
    if (card == null) return ClipRect(child: child);
    if (_dx == 0) return child;
    return ClipPath(clipper: _CardClip(card.inset, card.radius), child: child);
  }

  /// What a drag uncovers, in the card's place and shape where the row is a card.
  Widget _inCard(Widget ground) {
    final card = widget.card;
    if (card == null) return ground;
    return Padding(padding: card.inset, child: ClipRRect(borderRadius: BorderRadius.circular(card.radius), child: ground));
  }
}

/// Clips to the row's card: the box less [inset], with corners of [radius].
class _CardClip extends CustomClipper<Path> {
  const _CardClip(this.inset, this.radius);
  final EdgeInsets inset;
  final double radius;

  @override
  Path getClip(Size size) => Path()..addRRect(RRect.fromRectAndRadius(inset.deflateRect(Offset.zero & size), Radius.circular(radius)));

  @override
  bool shouldReclip(_CardClip old) => old.inset != inset || old.radius != radius;
}
