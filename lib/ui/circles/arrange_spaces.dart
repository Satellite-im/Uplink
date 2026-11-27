/// Arranging a circle's spaces: dragged into a new order by their handles, renamed, given a heading or another kind,
/// or taken out. For whoever may change the circle (its owner and the admins they made); each change is a new
/// manifest, said to everyone in it (Circles.moveSpace and the rest).
library;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../circles/circles.dart';
import '../../kit/settings_type.dart';
import '../common.dart';
import '../dialup/bevel.dart';
import 'circle_face.dart';
import 'new_circle.dart';
import '../../l10n/words.dart';

/// The page: the circle with [seed]'s spaces in their order, read again each time the circle changes.
class ArrangeCircleSpacesScreen extends StatelessWidget {
  const ArrangeCircleSpacesScreen({super.key, required this.seed});
  final String seed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final circles = Circles.instance;
    return ListenableBuilder(
      listenable: circles,
      builder: (context, _) {
        final c = circles.bySeed(seed);
        if (c == null) return GhostPage(title: 'Spaces', body: const Center(child: Tr('You left this circle.')));
        final spaces = c.spaces;
        final edit = circles.can(c, CirclePerm.spaces);
        final bevel = isBevelChrome(t);
        return GhostPage(
          title: 'Spaces in ${c.name}',
          actions: [
            if (edit) IconTap(key: const ValueKey('arrange-new-space'), icon: Lucide.plus, label: 'New space', size: 20, onPressed: () => push<void>(context, (_) => NewCircleSpaceScreen(circle: c))),
          ],
          body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(2)),
              child: Text(
                edit ? 'Drag a space by its handle to move it. Press one to rename it, give it a heading or another kind, or take it out.' : 'Only the circle\'s owner and the admins they made can arrange its spaces.',
                style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'), height: 1.4),
              ),
            ),
            Expanded(
              child: ReorderableList(
                padding: EdgeInsets.only(bottom: t.space(8) + MediaQuery.paddingOf(context).bottom),
                itemCount: spaces.length,
                // The space dragged, lifted on the page's raised paper (Dial-Up's: on its silver).
                proxyDecorator: (child, _, _) => ColoredBox(color: bevel ? DialupColors.of(t).chrome : t.color('app-paper-3'), child: child),
                onReorderItem: (from, to) {
                  if (!edit || to == from) return;
                  circles.moveSpace(c, spaces[from].seed, to);
                },
                itemBuilder: (context, i) {
                  final s = spaces[i];
                  return _ArrangeRow(key: ValueKey('arrange-${s.seed}'), index: i, circle: c, space: s, edit: edit);
                },
              ),
            ),
          ]),
        );
      },
    );
  }
}

/// One space's row: its kind's mark, its name, and its kind and heading under it. Pressed by someone who may [edit],
/// it opens the space's menu.
class _ArrangeRow extends StatelessWidget {
  const _ArrangeRow({super.key, required this.index, required this.circle, required this.space, required this.edit});
  final int index;
  final Circle circle;
  final CircleSpace space;
  final bool edit;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final line = [spaceKindTitle(space.kind), if (space.section != null) space.section!].join(' · ');
    return GlacierPressable(
      onPressed: edit ? () => showArrangeSpaceMenu(context, circle, space) : null,
      semanticLabel: '${space.name}, $line',
      builder: (context, state) => Container(
        color: state.pressed ? t.color('app-paper-2') : const Color(0x00000000),
        padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2)),
        child: Row(children: [
          SpaceKindBadge(kind: space.kind, size: 32),
          SizedBox(width: t.space(3)),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(space.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'semibold')),
              Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
            ]),
          ),
          if (edit)
            ReorderableDragStartListener(
              index: index,
              child: Semantics(
                label: 'Move ${space.name}',
                child: Padding(padding: EdgeInsets.all(t.space(2)), child: AppIcon(Lucide.gripVertical, size: 20, color: t.color('app-ink-3'))),
              ),
            ),
        ]),
      ),
    );
  }
}

/// A space's choices while arranging: rename, heading, kind, take out.
void showArrangeSpaceMenu(BuildContext context, Circle c, CircleSpace s) {
  final circles = Circles.instance;
  showChoices(context, title: '${s.name} · ${spaceKindTitle(s.kind)}', choices: [
    Choice('Rename', Lucide.pencil, () => askCircleWords(context, title: 'Rename ${s.name}', initial: s.name, then: (name) => circles.updateSpace(c, s.seed, name: name))),
    Choice('Heading', Lucide.listTree, () => askCircleWords(context, title: 'Heading for ${s.name}', initial: s.section ?? '', hint: 'Spaces with the same heading are listed together. Leave it empty for none.', then: (h) => circles.updateSpace(c, s.seed, section: h.isEmpty ? null : h, clearSection: h.isEmpty))),
    for (final k in spaceKindsOffered)
      if (k != s.kind) Choice('Make it ${spaceKindTitle(k).toLowerCase()}', spaceKindIcon(k), () => circles.updateSpace(c, s.seed, kind: k), hint: spaceKindBlurb(k)),
    Choice('Delete space', Lucide.trash2, () => confirmRemoveCircleSpace(context, c, s), danger: true),
  ]);
}

/// Asks first, then takes [s] out of [c] for everyone.
void confirmRemoveCircleSpace(BuildContext context, Circle c, CircleSpace s) {
  showChoices(context, title: 'Delete ${s.name}? It goes from ${c.name} for everyone; messages already there stay on the phones that have them.', choices: [
    Choice('Delete space', Lucide.trash2, () async {
      final ok = await Circles.instance.removeSpace(c, s.seed);
      if (context.mounted) toast(context, ok ? '${s.name} deleted' : 'Couldn\'t delete ${s.name}', tone: ok ? GlacierToastTone.neutral : GlacierToastTone.danger);
    }, danger: true),
  ]);
}
