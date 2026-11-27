import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart' show HitTestEntry;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../kit/semantic_colors.dart';
import '../kit/settings_kit.dart' show settingsHue;
import '../kit/settings_type.dart';
import 'dialup/dialup.dart';

/// One place the navigation pill goes to: one ring.
class NavItem {
  const NavItem({required this.id, required this.icon, required this.label, this.short, this.count = 0, this.menu});
  final String id;
  final LucideIcon icon;

  /// The rows of a menu of its own, asked for as it opens: a press with the other button on the ring, or a long
  /// press where there is no other button, hangs the kit's menu over the ring with these in it (the kit's
  /// `GlacierMenuItem`, `GlacierMenuLabel` and `GlacierMenuSeparator`). Matt, 2026-11-14: "add a right click
  /// context menu to archive as well and settings to quick jump to settings sections", and then, of the sheet
  /// across the window it first was: "too large and way too wide", with a picture of a small list hung by the
  /// button it came from, its rows in groups.
  final List<Widget> Function(BuildContext context)? menu;

  /// What the ring is read aloud by, and shown by while the pointer rests on it.
  final String label;

  /// The word on Dial-Up's taskbar button where [label] is longer than the others: every button's word is drawn at
  /// one size, so a long one is said shorter rather than drawn smaller ("New" for New space). [label] stays its tip
  /// and what it is read aloud by.
  final String? short;

  /// A number worn on the ring's corner (on Archive, how many archived conversations are unread); nothing for none.
  final int count;
}

/// The navigation pill that floats at the foot of the list of conversations: a new chat, the messages, the
/// contacts, the archive, Settings. It was made for the Mac's sidebar (Matt, 2026-11-14: "at the bottom of the
/// desktop sidebar, add a navigation bar floating", then "use the same navigation pill that we use in ghost markdown
/// but horizontal instead of vertical") and is the phone's too since the two share a frame (lib/ui/shell.dart;
/// Matt, the same day: "the mobile app should gain the nav from desktop").
///
/// It is Ghost.md's dock (lib/shell/page_dock.dart at the repository's root: `PageDock`, `DockRing`, `DockTip`),
/// laid along where that one stands up, and as wide as the sidebar with its rings evenly along it: a pill of glass, a step of space round its rings and between them, a
/// hairline round it; each ring `--app-ring` across, the page's colour with a line round it and its mark in the
/// page's ink; the one shown now filled with ink, its mark in paper, as the dock's one filled ring is; a number on a
/// ring's corner, in red (the dock wears its own in ink; here Matt asked for red); and a ring's words over it while the pointer rests there, where the dock's
/// come up beside it.
///
/// On a wide phone (a folding phone opened out, a tablet) it stands up instead, as Ghost.md's does: its rings close
/// under one another in a pill no wider than a ring, at the foot of a strip of its own down the window's right
/// ([upright]; Matt, 2026-11-14: "on wider phones like my fold 8 make the navbar render vertically condensed on the
/// right of the screen like we do in ghost markdown"). The frame gives it that strip (lib/ui/shell.dart), so it
/// stands over nothing: not the Send button, not the newest messages.
class NavPill extends StatelessWidget {
  const NavPill({super.key, required this.items, required this.active, required this.onSelect, this.upright = false, this.head, this.hue});
  final List<NavItem> items;

  /// Something worn at the pill's head, before its first ring (above it stood up, left of it laid along): a circle's
  /// face on the circle's dock, so the dock says whose it is at a glance. Not on Dial-Up's taskbar.
  final Widget? head;

  /// One of the app's hues (lib/kit/settings_css.dart `data-hue`) the ring shown is filled with, in place of the
  /// accent: the circle's, on its dock. Each look settles a hue into its own page, as a circle's face is.
  final String? hue;

  /// Stood up, its rings a step apart head to foot, rather than laid along the list's foot and spread across it.
  final bool upright;

  /// The id of the item shown now.
  final String active;
  final ValueChanged<String> onSelect;

  /// How far in from the sidebar's foot the pill stands.
  static double inset(Tokens t) => t.space(4);

  /// How much of the list's end the pill stands over, with its room: what the list leaves clear there.
  static double clearance(Tokens t) => t.len('app-ring') + (t.space(2) + t.len('glacier-hairline')) * 2 + inset(t) * 2;

  /// Stood up: how wide the strip it stands in is, the pill and a step of room on either side of it.
  static double railWidth(Tokens t) => t.len('app-ring') + (t.space(2) + t.len('glacier-hairline')) * 2 + _railRoom(t) * 2;

  /// The room on either side of the pill stood up: a small step, since every bit of it is taken from the pane.
  static double _railRoom(Tokens t) => t.space(2);

  /// Stood up with [count] rings: how tall it is with its room above and below. A window shorter than this (a
  /// small phone on its side) has no room for it stood up.
  static double railHeight(Tokens t, int count) => t.len('app-ring') * count + t.space(2) * (count - 1) + (t.space(2) + t.len('glacier-hairline')) * 2 + inset(t) * 2;

  /// Dial-Up's taskbar ([build] under it): how tall it is above the screen's bottom inset. Two lines of light along
  /// its top, a step of silver, the buttons 48 high, a step of silver.
  static const double taskbarHeight = 2 + _taskbarPad * 2 + RetroButton.target;
  static const double _taskbarPad = 4;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (isBevelChrome(t)) return _taskbar(context, t);
    final gap = t.space(2);
    final radius = BorderRadius.circular(t.radius('full'));
    // The pill runs the sidebar's width and its rings stand evenly along it, the first and the last at its ends
    // (Matt, 2026-11-14: "Evenly space the icons across the bottom of the sidebar instead of condensing them to the
    // center").
    // In from the sidebar's sides by what it stands up from its foot, so the room round it is the same on all three
    // (Matt, 2026-11-16: "make the navbar width fit the full sidebar and justify the space between evenly and make
    // the space on the left and right even to the space on the bottom").
    final rings = [
      if (head != null) SizedBox.square(key: const ValueKey('nav-head'), dimension: t.len('app-ring'), child: Center(child: head)),
      for (final item in items)
        _Ring(key: ValueKey('nav-${item.id}'), item: item, shown: item.id == active, upright: upright, tinted: hue != null, onPressed: () => onSelect(item.id)),
    ];
    return Padding(
      padding: upright ? EdgeInsets.symmetric(horizontal: _railRoom(t), vertical: inset(t)) : EdgeInsetsDirectional.fromSTEB(inset(t), 0, inset(t), inset(t)),
      child: SizedBox(
        width: upright ? null : double.infinity,
        child: Semantics(
          container: true,
          label: 'Navigation',
          explicitChildNodes: true,
          child: ClipRRect(
            borderRadius: radius,
            // A nearly solid ground, not a blur of the list behind it: the blur was drawn again on every frame of every
            // scroll, under a ground that already hid most of it (Matt, 2026-11-17: "get the app functioning at max speed").
            child: RepaintBoundary(
              child: Container(
                padding: EdgeInsets.all(gap + t.len('glacier-hairline')),
                foregroundDecoration: BoxDecoration(border: Border.all(color: t.color('glacier-border-subtle'), width: t.len('glacier-hairline')), borderRadius: radius),
                decoration: BoxDecoration(color: t.colorOf('color-mix(in srgb, var(--glacier-bg) 94%, transparent)'), borderRadius: radius),
                child: _hued(upright
                    // Ghost.md's dock as it is there: head to foot, a step between its rings.
                    ? Column(mainAxisSize: MainAxisSize.min, spacing: gap, children: rings)
                    : Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: rings)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

extension on NavPill {
  Widget _hued(Widget child) => hue == null ? child : GlacierScope(attrs: {'hue': hue!}, child: child);

  /// Dial-Up's way round (Matt, 2026-11-16: "base one of them heavily on the old AOL chatrooms"): the era's taskbar, a
  /// silver strip the window's width along its foot with a line of light on top, holding one raised button per place,
  /// its picture over its name, the place shown now held in. No start button and no logo: the design keeps the
  /// strip and leaves the rest of that era's desktop alone. It stands under the list, not over it (lib/ui/shell.dart),
  /// and is not drawn under a conversation on a phone, as the pill is not.
  Widget _taskbar(BuildContext context, Tokens t) {
    final c = DialupColors.of(t);
    const pad = NavPill._taskbarPad;
    return Semantics(
      container: true,
      label: 'Navigation',
      explicitChildNodes: true,
      child: DecoratedBox(
        decoration: BoxDecoration(color: c.chrome, border: Border(top: BorderSide(color: c.hi))),
        child: Padding(
          padding: const EdgeInsets.only(top: 1),
          child: DecoratedBox(
            decoration: BoxDecoration(border: Border(top: BorderSide(color: c.lo))),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(pad, pad, pad, pad - 1),
              child: SizedBox(
                height: RetroButton.target,
                child: Row(spacing: pad, children: [
                  for (final item in items)
                    Expanded(child: _Ring(key: ValueKey('nav-${item.id}'), item: item, shown: item.id == active, onPressed: () => onSelect(item.id))),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One ring as the pill draws it, on its own: for the rail at the window's left (lib/ui/nav_rail.dart), whose rings
/// are the pill's, with their counts, their menus and their words, these to their right.
class NavRing extends StatelessWidget {
  const NavRing({super.key, required this.item, required this.shown, required this.onPressed});
  final NavItem item;
  final bool shown;
  final VoidCallback onPressed;

  /// The rail's rings are a little smaller than the pill's (`--app-rail-ring`), their marks with them.
  @override
  Widget build(BuildContext context) => _Ring(item: item, shown: shown, onPressed: onPressed, beside: true, ringToken: 'app-rail-ring');
}

/// One ring of the pill (the dock's `DockRing`): quiet, or filled with ink when it is the one shown. One with a
/// menu of its own ([NavItem.menu]) hangs it over itself.
class _Ring extends StatefulWidget {
  const _Ring({super.key, required this.item, required this.shown, required this.onPressed, this.upright = false, this.tinted = false, this.beside = false, this.ringToken = 'app-ring'});
  final NavItem item;

  /// The token its side is read from: the rail's own, smaller, for [NavRing].
  final String ringToken;
  final bool shown;

  /// Shown, it is filled with the hue round it ([NavPill.hue]) rather than the accent.
  final bool tinted;

  /// In a pill stood up at the window's right: its words keep their right edge on the ring's, inside the window.
  final bool upright;

  /// In the rail at the window's left (lib/ui/nav_rail.dart): its words and its menu to its right, towards the list.
  final bool beside;
  final VoidCallback onPressed;

  @override
  State<_Ring> createState() => _RingState();
}

class _RingState extends State<_Ring> {
  /// Its menu is open, and the rows it opened with: kept while it closes, so it does not empty as it goes.
  bool _open = false;
  List<Widget> _rows = const [];

  /// On the ring, for its menu to hang from.
  final GlobalKey _ringKey = GlobalKey(debugLabel: 'navigation ring');

  /// A press with the other button, or a long press where there is no other button.
  void _showMenu() {
    final rows = widget.item.menu?.call(context) ?? const <Widget>[];
    if (rows.isEmpty) return;
    setState(() {
      _rows = rows;
      _open = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final round = _round(context);
    if (widget.item.menu == null) return round;
    // A small list by the ring it came from, its right edge on the ring's, no wider than its longest row needs and
    // no taller than the window has room for: more rows than that scroll inside it. It hangs from the ring as
    // though the ring were as tall as the pill round it, so it stands clear of the pill, a gap between the two:
    // hung from the ring itself its foot lay on the pill's top edge, and it read as going behind the bar (Matt,
    // 2026-11-14: "the context menu is rendering behind the navbar").
    return GlacierMenu(
      open: _open,
      onOpenChange: (open) {
        if (!open && _open) setState(() => _open = false);
      },
      // Over the ring where the pill is laid along; beside it, towards the pane, where the pill is stood up and
      // over the ring is another ring. From the pill's edge either way, not the ring's.
      anchor: _RingAnchor(_ringKey, t.space(2) + t.len('glacier-hairline'), sideways: widget.upright || widget.beside),
      placement: widget.beside ? Placement.rightEnd : (widget.upright ? Placement.leftEnd : Placement.topEnd),
      ariaLabel: widget.item.label,
      style: GlacierMenuStyle(
        minWidth: t.lenOf('12.5rem'),
        maxWidth: t.lenOf('15rem'),
        maxHeight: math.max(t.lenOf('10rem'), math.min(t.lenOf('26rem'), MediaQuery.sizeOf(context).height - t.len('app-ring') - t.lenOf('7rem'))),
      ),
      trigger: (context, trigger) => KeyedSubtree(key: _ringKey, child: round),
      children: _rows,
    );
  }

  Widget _round(BuildContext context) {
    final t = context.tokens;
    if (isBevelChrome(t)) return _task(context, t);
    final item = widget.item;
    final shown = widget.shown;
    final onPressed = widget.onPressed;
    final onMenu = item.menu == null ? null : _showMenu;
    final ring = t.len(widget.ringToken);
    // The mark shrinks with its ring where the ring is the rail's.
    final scale = ring / t.len('app-ring');
    final size = (shown ? 18.0 : t.lenOf('1.15rem')) * scale;
    final stroke = shown ? 2.2 : 2.0;
    // The page shown wears the app's accent (lib/accent.dart); on a circle's dock, the circle's hue, its mark in the
    // page's ground as a circle's face filled with its hue has it.
    final tinted = widget.tinted;
    final ink = shown ? t.color(tinted ? 'glacier-bg' : 'app-on-accent') : t.color('glacier-text');
    return HoverTip(
      message: item.label,
      end: widget.upright,
      beside: widget.beside,
      child: GestureDetector(
       behavior: HitTestBehavior.translucent,
       onSecondaryTapUp: onMenu == null ? null : (_) => onMenu(),
       onLongPress: onMenu,
       child: GlacierPressable(
        onPressed: onPressed,
        semanticLabel: item.label,
        builder: (context, state) {
          final mark = AppIcon(item.icon, size: size, strokeWidth: stroke, color: ink, wash: false);
          final Widget round = shown
              ? GlacierFocusRing(
                  visible: state.focused,
                  offset: 3,
                  color: t.color('app-ink'),
                  child: AnimatedScale(
                    scale: state.pressed ? 0.98 : 1,
                    duration: t.duration('glacier-duration-fast'),
                    curve: t.curve('glacier-ease-out'),
                    child: Container(
                      width: ring,
                      height: ring,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: tinted ? settingsHue(t) : t.color('app-accent'), borderRadius: BorderRadius.circular(t.radius('full'))),
                      child: mark,
                    ),
                  ),
                )
              : GlacierFocusRing(
                  visible: state.focused,
                  child: Container(
                    width: ring,
                    height: ring,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: t.color(state.hovered || state.pressed ? 'app-paper-2' : 'glacier-bg'),
                      // The kit's pill radius rather than a circle, so a look's own (`--glacier-radius-full`) reaches it.
                      borderRadius: BorderRadius.circular(t.radius('full')),
                      border: Border.all(color: t.color('glacier-border-strong'), width: t.len('app-line')),
                    ),
                    child: mark,
                  ),
                );
          if (item.count <= 0) return round;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              round,
              PositionedDirectional(
                end: -4,
                top: -4,
                child: ExcludeSemantics(
                  child: Container(
                    // Large enough to read at a glance, and red: a count is the one thing on the pill that is not
                    // the page's own ink (Matt, 2026-11-14: "the badge is too small and it doesn't look like it's
                    // the right color make it red"). It was fourteen across in the page's ink, which on the ring
                    // that is shown (itself ink) read as a hole in it. A line of the page's ground round it keeps
                    // it off the ring in either case.
                    // A size larger again (Matt, 2026-11-15: "make the notification count badges a bit bigger").
                    // And larger once more (Matt, 2026-11-18: "The notification badges are too small"), which at
                    // 26 across with 14-point words went past it (Matt, 2026-11-22: "the pill for unread count is too
                    // big"): 20 across and 12-point, as a circle's count in the rail is near enough.
                    constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: t.danger, borderRadius: BorderRadius.circular(10), border: Border.all(color: t.color('glacier-bg'), width: 2)),
                    child: Text(item.count > 99 ? '99+' : '${item.count}', style: t.textAt(12, weight: 'bold', height: 1.15, color: const Color(0xFFFFFFFF))),
                  ),
                ),
              ),
            ],
          );
        },
       ),
      ),
    );
  }
}

extension on _RingState {
  /// A taskbar button (NavPill under Dial-Up): its picture over its name, held in while its place is shown, on the
  /// lighter face the era gave the window in front; a count on its corner in a small red square. Its name shrinks
  /// to fit rather than being cut, since five go across a phone 360 wide.
  Widget _task(BuildContext context, Tokens t) {
    final item = widget.item;
    final shown = widget.shown;
    final c = DialupColors.of(t);
    final onMenu = item.menu == null ? null : _showMenu;
    // In the rail (lib/ui/nav_rail.dart): a square push button of the ring's own size, its picture alone, as a side
    // panel's tabs are; its name is its tip, beside it. A strip's button, as wide as its share, has no width to take
    // in a column, and laid nothing out there.
    if (widget.beside) {
      final side = t.len(widget.ringToken);
      final tab = RetroButton(
        onPressed: widget.onPressed,
        onLongPress: onMenu,
        semanticLabel: item.count > 0 ? '${item.label}, ${item.count}' : item.label,
        toggled: shown,
        face: shown && !c.night ? c.lo : null,
        faceHeight: side,
        minFaceWidth: side,
        padding: EdgeInsets.zero,
        child: AppIcon(item.icon, size: 18, strokeWidth: shown ? 2.2 : 2, color: c.onChrome, wash: false),
      );
      return HoverTip(
        message: item.label,
        beside: true,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onSecondaryTapUp: onMenu == null ? null : (_) => onMenu(),
          child: item.count <= 0
              ? tab
              : Stack(clipBehavior: Clip.none, children: [
                  tab,
                  PositionedDirectional(end: -2, top: -2, child: IgnorePointer(child: ExcludeSemantics(child: DialupCount(count: item.count)))),
                ]),
        ),
      );
    }
    final button = RetroButton(
      onPressed: widget.onPressed,
      onLongPress: onMenu,
      semanticLabel: item.count > 0 ? '${item.label}, ${item.count}' : item.label,
      toggled: shown,
      face: shown && !c.night ? c.lo : null,
      faceHeight: RetroButton.target,
      // As wide as its share of the strip.
      minFaceWidth: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        AppIcon(item.icon, size: 18, color: c.onChrome, wash: false),
        const SizedBox(height: 2),
        FittedBox(fit: BoxFit.scaleDown, child: Text(item.short ?? item.label, maxLines: 1, softWrap: false, style: pageText(t, 12, weight: shown ? 'bold' : 'regular', color: c.onChrome, height: 1.2))),
      ]),
    );
    return HoverTip(
      message: item.label,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapUp: onMenu == null ? null : (_) => onMenu(),
        child: item.count <= 0
            ? button
            : Stack(clipBehavior: Clip.none, children: [
                Positioned.fill(child: button),
                PositionedDirectional(end: 3, top: 3, child: IgnorePointer(child: ExcludeSemantics(child: DialupCount(count: item.count)))),
              ]),
      ),
    );
  }
}

/// What a ring's menu hangs from: the ring, taken to reach [reach] past its top and its foot, which is as far as
/// the pill round it does (past its sides, in a pill stood up: [sideways]). A press on the ring is not a press
/// outside its menu.
class _RingAnchor extends GlacierAnchor {
  const _RingAnchor(this.key, this.reach, {this.sideways = false});
  final GlobalKey key;
  final double reach;
  final bool sideways;

  RenderBox? get _box {
    final object = key.currentContext?.findRenderObject();
    return object is RenderBox && object.attached && object.hasSize ? object : null;
  }

  @override
  Rect? rect() {
    final box = _box;
    if (box == null) return null;
    final ring = MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);
    return sideways ? Rect.fromLTRB(ring.left - reach, ring.top, ring.right + reach, ring.bottom) : Rect.fromLTRB(ring.left, ring.top - reach, ring.right, ring.bottom + reach);
  }

  @override
  TextDirection? direction() => key.currentContext?.getInheritedWidgetOfExactType<Directionality>()?.textDirection;

  @override
  bool holds(Iterable<HitTestEntry> path, Offset position) {
    final box = _box;
    return box != null && path.any((entry) => identical(entry.target, box));
  }

  @override
  bool operator ==(Object other) => other is _RingAnchor && other.key == key && other.reach == reach && other.sideways == sideways;

  @override
  int get hashCode => Object.hash(key, reach, sideways);
}

/// A ring's words while the pointer rests on it (the dock's `DockTip`): over the ring here, since the pill lies
/// along the sidebar's foot and beside a ring is another ring.
///
/// Any button that is a picture alone can wear one ([below]: under it, for one near the top of its column; [end]:
/// its right edge on the button's, for one at its column's right).
class HoverTip extends StatefulWidget {
  const HoverTip({super.key, required this.message, required this.child, this.below = false, this.end = false, this.beside = false});
  final String message;
  final Widget child;
  final bool below;
  final bool end;

  /// To its right, level with it: for a button in a column at the window's left (the rail).
  final bool beside;

  @override
  State<HoverTip> createState() => _HoverTipState();
}

class _HoverTipState extends State<HoverTip> {
  final OverlayPortalController _portal = OverlayPortalController(debugLabel: 'navigation tip');
  final LayerLink _link = LayerLink();
  Timer? _waiting;

  @override
  void dispose() {
    _waiting?.cancel();
    super.dispose();
  }

  void _enter() {
    _waiting?.cancel();
    _waiting = Timer(const Duration(milliseconds: 450), () {
      if (mounted && Overlay.maybeOf(context) != null) _portal.show();
    });
  }

  void _exit() {
    _waiting?.cancel();
    if (_portal.isShowing) _portal.hide();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return MouseRegion(
      onEnter: (_) => _enter(),
      onExit: (_) => _exit(),
      child: Listener(
        onPointerDown: (_) => _exit(),
        child: OverlayPortal(
          controller: _portal,
          overlayChildBuilder: (context) => PositionedDirectional(
            start: 0,
            top: 0,
            child: CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              targetAnchor: widget.beside ? Alignment.centerRight : widget.below ? (widget.end ? Alignment.bottomRight : Alignment.bottomCenter) : (widget.end ? Alignment.topRight : Alignment.topCenter),
              followerAnchor: widget.beside ? Alignment.centerLeft : widget.below ? (widget.end ? Alignment.topRight : Alignment.topCenter) : (widget.end ? Alignment.bottomRight : Alignment.bottomCenter),
              offset: widget.beside ? Offset(t.space(3), 0) : Offset(0, widget.below ? t.space(2) : -t.space(3)),
              child: IgnorePointer(
                child: ExcludeSemantics(
                  // Dial-Up's tip is the era's pale yellow in a thin black line, and Runestone's the game's (`--app-tooltip`).
                  child: isBevelChrome(t)
                      ? Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          decoration: BoxDecoration(color: DialupColors.of(t).tooltip, border: Border.all(color: DialupColors.of(t).onTooltip)),
                          child: Text(widget.message, maxLines: 1, softWrap: false, style: t.textAt(13, height: 1.3, color: DialupColors.of(t).onTooltip)),
                        )
                      : Container(
                          padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: t.space(1)),
                          decoration: BoxDecoration(color: t.color('app-ink'), borderRadius: BorderRadius.circular(t.radius('sm'))),
                          child: Text(widget.message, maxLines: 1, softWrap: false, style: t.textAt(t.fontSize('xs'), weight: 'medium', height: 1.3, color: t.color('app-paper'))),
                        ),
                ),
              ),
            ),
          ),
          child: CompositedTransformTarget(link: _link, child: widget.child),
        ),
      ),
    );
  }
}
