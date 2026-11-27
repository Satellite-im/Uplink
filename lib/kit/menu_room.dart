/// The room a menu has on screen beside the button it hangs from (Matt, 2026-11-20: "the filter popover goes off
/// screen it should make sure it renders on screen").
///
/// The kit (GlacierAnchored) puts a panel on the side it is asked for, turns it to the other side only when it fits
/// there whole, and never makes it shorter: a long menu under a button low in the window ran off the window's foot.
/// [MenuRoom.of] measures the button against the overlay the kit draws in, less the system's bars and the keyboard,
/// and says which side has more room and how tall and wide a panel may be to stay inside it. A panel no bigger than
/// that fits where it is put, and the kit has no cause to turn it.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

/// The side a panel goes on, and the most it may measure there.
class MenuRoom {
  const MenuRoom({required this.below, required this.height, required this.width});

  /// GlacierAnchored's own: the gap between a button and its panel (`offset`), and the margin it keeps from the
  /// overlay's edges (`padding`).
  static const gap = 8.0, margin = 8.0;

  /// The panel goes below the button; else above it.
  final bool below;

  /// The tallest the panel may be on that side.
  final double height;

  /// The widest it may be.
  final double width;

  /// [placement] on the side with the room, its alignment kept.
  Placement place(Placement placement) => Placement.of(below ? PhysicalSide.bottom : PhysicalSide.top, placement.align);

  /// Measured from [context], the button's, where it was last laid out; null before it has been.
  static MenuRoom? of(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    // What can be seen: the window less its bars and the keyboard, as the window has them (a page's own MediaQuery
    // may have taken them away already), inside the overlay the kit draws in.
    final view = MediaQueryData.fromView(View.of(context));
    final foot = math.max(view.padding.bottom, view.viewInsets.bottom);
    var area = Rect.fromLTRB(view.padding.left, view.padding.top, view.size.width - view.padding.right, view.size.height - foot);
    final overlay = Overlay.maybeOf(context, rootOverlay: true)?.context.findRenderObject();
    if (overlay is RenderBox && overlay.attached && overlay.hasSize) area = area.intersect(overlay.localToGlobal(Offset.zero) & overlay.size);
    final button = box.localToGlobal(Offset.zero) & box.size;
    final below = area.bottom - margin - (button.bottom + gap);
    // A pixel short of it: the kit turns a panel up only when it fits there with room to spare.
    final above = button.top - gap - (area.top + margin) - 1;
    return MenuRoom(below: below >= above, height: math.max(0, math.max(below, above)), width: math.max(0, area.width - margin * 2));
  }
}
