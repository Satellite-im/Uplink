/// Who is in a space or a circle, in a drawer that slides up as the Add people drawer does (Matt, 2026-11-17: "the
/// member list should show up as a drawer like the add user, it should include a button to switch to add user at the
/// top"). It had been a list put in the chat's place by a button in the space's header.
///
/// The drawer is the invite drawer's own presentation (lib/ui/space_invite.dart `showSpaceInvite`,
/// lib/ui/circles/circle_invite.dart `showCircleInvite`): raised over everything on the outermost navigator, the
/// page dimmed behind it, sliding up from the foot, a round-cornered card no wider than 30rem (Dial-Up's square raised
/// window). Add people at its top closes it and opens that drawer in its place.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../circles/circles.dart';
import '../../kit/semantic_colors.dart';
import '../../kit/settings_kit.dart';
import '../../kit/settings_type.dart';
import '../../voice/channels.dart' show Voice;
import '../dialup/bevel.dart';
import '../verified_badge.dart';
import '../drawer_head.dart';
import '../ripple_avatar.dart';
import 'circle_face.dart';
import 'circle_invite.dart';
import 'new_circle.dart';

/// Raises the members drawer over everything: [title] and [subtitle] at its top, then Add people, then [list] (a
/// scrollable that shrinks to what it holds, so a short list makes a short drawer). [onAddPeople] is what Add people
/// opens once the drawer has gone; null leaves the button out (a group's space, which nobody is invited into).
/// [mayAdd] false shows it greyed, for someone the space does not let invite.
Future<void> showMembersDrawer(
  BuildContext context, {
  required String title,
  String? subtitle,
  Widget? face,
  required WidgetBuilder list,
  VoidCallback? onAddPeople,
  bool mayAdd = true,
}) {
  return Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
    opaque: false,
    barrierDismissible: true,
    barrierColor: context.tokens.sheetScrim,
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, _, _) => MembersDrawer(title: title, subtitle: subtitle, face: face, list: list, onAddPeople: onAddPeople, mayAdd: mayAdd),
    transitionsBuilder: (context, a, _, child) => SlideTransition(
      position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
      child: child,
    ),
  ));
}

/// A circle's members in the drawer: its owner, its admins and everyone seen in it, Add people opening the circle's
/// invite drawer.
Future<void> showCircleMembers(BuildContext context, Circle c) => showMembersDrawer(
      context,
      title: 'Members',
      subtitle: c.name,
      face: CircleFace.of(c, size: 40),
      list: (_) => CircleMembersList(seed: c.seed),
      onAddPeople: () => showCircleInvite(context, c),
    );

/// The drawer itself.
class MembersDrawer extends StatelessWidget {
  const MembersDrawer({super.key, required this.title, this.subtitle, this.face, required this.list, this.onAddPeople, this.mayAdd = true});
  final String title;
  final String? subtitle;

  /// The circle's face beside the title, as the circle's invite drawer has it.
  final Widget? face;
  final WidgetBuilder list;
  final VoidCallback? onAddPeople;
  final bool mayAdd;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final pad = MediaQuery.paddingOf(context);
    // Above the keyboard while one is up, so a field in the drawer (Share feedback's) isn't under it.
    final foot = math.max(pad.bottom, MediaQuery.viewInsetsOf(context).bottom);
    final add = onAddPeople;
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(3), 0, t.space(3), foot + t.space(3)),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: t.lenOf('30rem'), maxHeight: math.max(t.lenOf('12rem'), MediaQuery.sizeOf(context).height - pad.top - foot - t.space(8))),
          child: _Frame(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // The invite drawer's own head (lib/ui/drawer_head.dart): the same words in the same places.
              DrawerHead(title: title, subtitle: subtitle, face: face, closeKey: const ValueKey('members-close')),
              // Add people at the top: the drawer gives way to the invite drawer, raised from where this one was.
              if (add != null)
                Padding(
                  padding: EdgeInsetsDirectional.fromSTEB(DrawerHead.gutter(t), t.space(2), DrawerHead.gutter(t), t.space(2)),
                  child: _AddPeopleButton(
                    onPressed: mayAdd
                        ? () {
                            Navigator.of(context).pop();
                            add();
                          }
                        : null,
                  ),
                ),
              Container(height: t.len('glacier-hairline'), color: t.color('app-rule')),
              Flexible(child: list(context)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Add people, as the invite drawer's Send button is drawn: the page's ink, round; Dial-Up's raised button that sinks
/// while pressed. Greyed where this device may not invite.
class _AddPeopleButton extends StatelessWidget {
  const _AddPeopleButton({required this.onPressed});
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    final off = onPressed == null;
    return GlacierPressable(
      key: const ValueKey('members-add-people'),
      onPressed: onPressed,
      semanticLabel: 'Add people',
      builder: (context, state) {
        final ink = bevel ? (off ? DialupColors.of(t).disabled : DialupColors.of(t).onChrome) : t.color(off ? 'app-ink-3' : 'app-paper');
        final words = Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          AppIcon(Lucide.userPlus, size: 16, wash: false, color: ink),
          SizedBox(width: t.space(2)),
          Text('Add people', style: pageText(t, t.fontSize('md'), weight: 'bold', color: ink)),
        ]);
        if (bevel) return Bevel(style: state.pressed && !off ? BevelStyle.sunken : BevelStyle.raised, padding: EdgeInsets.symmetric(vertical: t.space(3) - 2), child: words);
        return Container(
          padding: EdgeInsets.symmetric(vertical: t.space(3) - 2),
          decoration: BoxDecoration(color: t.color(off ? 'app-paper-3' : (state.pressed ? 'app-ink-2' : 'app-ink')), borderRadius: BorderRadius.circular(t.radius('full'))),
          child: words,
        );
      },
    );
  }
}

/// The drawer's card: the page's raised paper, round-cornered; Dial-Up's square raised window, its list in the
/// window's white well as its other lists are.
class _Frame extends StatelessWidget {
  const _Frame({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (isBevelChrome(t)) return Bevel(child: child);
    return ClipRRect(borderRadius: BorderRadius.circular(t.radius('xl')), child: ColoredBox(color: t.color('app-paper-2'), child: child));
  }
}

/// A circle's people, as its settings list them (circlePeople): the owner, the admins, then everyone else seen in it,
/// each with their face, whether they are on now, and their role. The owner presses someone to make them an admin or
/// take it back.
class CircleMembersList extends StatelessWidget {
  const CircleMembersList({super.key, required this.seed});
  final String seed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final circles = Circles.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([circles, Voice.instance]),
      builder: (context, _) {
        final c = circles.bySeed(seed);
        if (c == null) return Padding(padding: EdgeInsets.all(t.space(6)), child: Text('You left this circle.', textAlign: TextAlign.center, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))));
        final people = circlePeople(c);
        final here = people.where((p) => p.here).length;
        final groups = [
          ('Owner', [for (final p in people) if (p.owner) p]),
          ('Admins', [for (final p in people) if (p.admin) p]),
          ('Members', [for (final p in people) if (!p.owner && !p.admin) p]),
        ];
        // The count line and each role's heading on the drawer's gutter, as its head and Add people are; the rows are
        // in only by their own padding.
        return ListView(
          shrinkWrap: true,
          padding: EdgeInsetsDirectional.fromSTEB(DrawerHead.gutter(t), t.space(3), DrawerHead.gutter(t), t.space(4)),
          children: [
            Padding(
              padding: EdgeInsets.only(bottom: t.space(3)),
              child: Text('${people.length} ${people.length == 1 ? 'person' : 'people'} · $here on now', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
            ),
            for (final (name, group) in groups)
              if (group.isNotEmpty) ...[
                DrawerHeading('$name · ${group.length}'),
                PaneSection(
                  children: [
                    for (final p in group)
                      SettingRow(
                        key: ValueKey('circle-member-${p.id}'),
                        // Your face from your own name, as a space's members list draws it.
                        icon: Opacity(opacity: p.here ? 1 : 0.5, child: RippleAvatar(name: p.me ? youFaceName() : p.name, level: 0, size: 30)),
                        label: p.name,
                        // The verified-number badge where they verified a number (Matt, 2026-11-19).
                        labelAfter: VerifiedBadge(id: p.id, me: p.me, size: 14),
                        // Their role's colour instead of a tag (Matt, 2026-11-17; the owner's crown went 2026-11-18).
                        labelColor: circleRoleInk(t, p),
                        hint: Text(p.here ? 'On now' : 'Away'),
                        // Their profile card (Matt, 2026-11-19: "Clicking on a users profile picture or name should open
                        // the profile drawer as well"), with what this device may change about them in the circle.
                        onPress: () => circlePersonMenu(context, c, p),
                      ),
                  ],
                ),
                SizedBox(height: t.space(4)),
              ],
          ],
        );
      },
    );
  }
}
