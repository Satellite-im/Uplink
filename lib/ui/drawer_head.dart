/// The head of the drawers that slide up over a space or a circle: Members and Invite people (Matt, 2026-11-17: "the
/// member list should show up as a drawer like the add user"). One head for both, so moving from one to the other
/// changes the words and nothing else: the place's face where it has one, a title, the space's or circle's name under
/// it, and Close in the same corner.
library;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/lucide.g.dart';
import '../kit/settings_type.dart';
import '../me/me.dart';
import 'common.dart' show IconTap;
import 'dialup/bevel.dart' show isBevelChrome;

/// The head itself: the face, the title over the name and a note, and Close at the end.
class DrawerHead extends StatelessWidget {
  const DrawerHead({super.key, required this.title, this.subtitle, this.face, this.note, this.closeKey});
  final String title;

  /// The space's or circle's name.
  final String? subtitle;

  /// The circle's face, where the drawer is a circle's.
  final Widget? face;

  /// A line under the name, where the drawer has more to say (whoever has a circle's link is in it).
  final String? note;

  /// The close button's key, for a test.
  final Key? closeKey;

  /// The room the drawers' own rows keep from the card's sides: the head's words, the count line and the role headings
  /// all start here, so the drawer reads down one edge.
  static double gutter(Tokens t) => t.space(4);

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(gutter(t), t.space(3), t.space(2), 0),
      child: Row(children: [
        if (face != null) ...[face!, SizedBox(width: t.space(3))],
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('lg'), weight: 'bold', color: t.color('app-ink'))),
            if (subtitle != null) Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
            if (note != null) Text(note!, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
          ]),
        ),
        IconTap(key: closeKey ?? const ValueKey('drawer-close'), icon: Lucide.x, label: 'Close', size: 18, onPressed: () => Navigator.of(context).maybePop()),
      ]),
    );
  }
}

/// A part of a drawer's list by role ("Owner · 1"), on the drawer's gutter: the settings pages' small capitals
/// (PaneSection's title), without the step in that PaneSection gives its own.
class DrawerHeading extends StatelessWidget {
  const DrawerHeading(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final size = t.lenOf('0.72rem');
    final bevel = isBevelChrome(t);
    return Padding(
      padding: EdgeInsets.only(bottom: t.space(2)),
      child: Semantics(
        label: text,
        child: ExcludeSemantics(
          child: Text(bevel ? text : text.toUpperCase(), style: pageText(t, size, weight: 'semibold', color: t.color('app-ink-3'), tracking: t.len('app-tracking-caps', em: size))),
        ),
      ),
    );
  }
}

/// The name your own face is drawn from in a members list, the same in a circle's and a space's: your name as friends
/// see it, else your username, else "You".
String youFaceName([Me? me]) {
  final m = me ?? Me.instance;
  if (m.displayName.trim().isNotEmpty) return m.displayName.trim();
  return m.username ?? 'You';
}
