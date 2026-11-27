import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../app_state.dart';
import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../changelog.dart';
import '../kit/settings_type.dart';
import '../sms.dart' show Sms;
import 'circles/members_drawer.dart' show showMembersDrawer;
import 'common.dart' show GhostLogo;
import 'drawer_head.dart' show DrawerHead, DrawerHeading;
import 'settings_panes.dart' show appVersion;

/// What's new: the release notes (lib/changelog.dart) in the app's drawer, once after each update and again from
/// Settings › About (Matt, 2026-11-19: "Implement a changelog that pops up ever time a new update is released with
/// release notes").

/// The version whose notes were last shown (or that was first installed), kept with the device's choices.
const changelogSeenKey = 'changelog_seen';

/// Shows what came since this device last saw the notes, where anything did: called once the app's frame is up. A new
/// install shows nothing (its walkthrough says what the app does) and starts from the version it is. Notes are marked
/// seen as they are shown, so they come up once.
Future<void> showWhatsNewIfUpdated(BuildContext context, {String current = appVersion}) async {
  final app = AppState.of(context);
  final seen = app.choice(changelogSeenKey, '');
  if (seen == current) return;
  app.set(changelogSeenKey, current);
  // From before the notes were kept: a phone that has been set up has been used, so it has updated into them; a
  // phone still to be set up is new. A computer or an iPhone can't tell a new install from an update, so it starts
  // from the version it is and is shown the notes from its next update on.
  if (seen.isEmpty && (Sms.remote || !app.flag('onboarded', fallback: false))) return;
  final notes = seen.isEmpty ? notesSince('', current, most: 1) : notesSince(seen, current);
  if (notes.isEmpty || !context.mounted) return;
  await showWhatsNew(context, notes);
}

/// [notes] in the drawer, newest first; the newest release's when none are given.
Future<void> showWhatsNew(BuildContext context, [List<ReleaseNotes>? notes]) {
  final shown = notes ?? changelog.take(1).toList();
  return showMembersDrawer(
    context,
    title: 'What\'s new',
    subtitle: shown.length == 1 ? 'Uplink ${shown.single.version}' : 'Since you last looked',
    face: const GhostLogo(size: 40),
    list: (_) => WhatsNewList(notes: shown),
  );
}

/// The mark a note is shown with (Matt, 2026-11-19: "use iconography and smaller text on release notes"): read from what
/// the note is about, its name before a colon first ("Record call: …") and then its words, so the notes stay plain lines
/// in lib/changelog.dart. The first rule that matches wins; a sparkle where none does.
LucideIcon noteIcon(String note) {
  final colon = note.indexOf(':');
  final title = (colon > 0 && colon < 40 ? note.substring(0, colon) : '').toLowerCase();
  final all = note.toLowerCase();
  for (final words in [title, all]) {
    if (words.isEmpty) continue;
    for (final (keys, icon) in _noteIcons) {
      if (keys.any(words.contains)) return icon;
    }
  }
  return Lucide.sparkles;
}

final List<(List<String>, LucideIcon)> _noteIcons = [
  // Before the plainer words below: an open space is not any space, and a line of fixes names many things.
  (['open space'], Lucide.compass),
  // The look Runestone and its textures (Matt, 2026-11-27): a quest's scroll, as the look's own mark is.
  (['runestone'], Lucide.scrollText),
  // The looks and what each is drawn with (Matt, 2026-11-27: "add texture packs to all themes"): a palette, as making
  // a look of your own is marked. After Runestone's, so its own notes keep the scroll.
  (['textures', 'four looks'], Lucide.palette),
  (['ai model'], Lucide.wandSparkles),
  (['language'], LucideMore.languages),
  (['fixes'], Lucide.listChecks),
  (['replies on'], LucideMore.reply),
  (['share screen'], LucideMore.screenShare),
  (['splash'], LucideMore.rocket),
  // Keyboard shortcuts (GMFB-41).
  (['keyboard shortcuts'], LucideMore.keyboard),
  // Running your own relay (GMFB-25).
  (['relay server'], Lucide.hardDrive),
  // The Marketplace and plugins from other developers (Matt, 2026-11-20): before developer mode, which loads them too.
  (['marketplace', 'make your own'], Lucide.store),
  (['custom css'], Lucide.palette),
  (['chat map'], Lucide.zoomIn),
  (['developer mode'], Lucide.braces),
  (['icons', 'app icon', 'phosphor'], Lucide.shapes),
  (['sign up', 'sign-up', 'signing in'], Lucide.userPlus),
  (['souls', 'flame'], Lucide.flame),
  (['badge'], LucideMore.badgeCheck),
  // The docs at gogho.st/docs (Matt, 2026-11-19: "Spend time creating a /docs/ page on ghost messaging").
  (['help and docs', 'gogho.st/docs'], Lucide.bookOpen),
  (['signed', 'publisher'], Lucide.shieldCheck),
  (['verified'], LucideMore.badgeCheck),
  (['slow mode'], Lucide.hourglass),
  (['poll'], LucideMore.chartColumn),
  (['feedback', 'bug bount'], LucideMore.messageSquareWarning),
  (['top bar'], Lucide.laptop),
  (['record'], Lucide.circleDot),
  (['scribe', 'written out', 'transcri'], Lucide.scrollText),
  (['caption'], Lucide.text),
  (['soundboard'], Lucide.megaphone),
  (['voice changer'], Lucide.audioLines),
  (['watch together', 'video', 'film'], Lucide.film),
  (['sms', 'by text', 'texting'], Lucide.smartphone),
  (['mention', '@'], Lucide.atSign),
  (['what\'s new', 'changelog'], Lucide.sparkles),
  (['plugin'], Lucide.puzzle),
  (['profile', 'status'], Lucide.circleUser),
  (['banner', 'picture', 'photo'], Lucide.image),
  (['remove', 'ban'], Lucide.userMinus),
  (['code'], Lucide.keyRound),
  (['contact', 'friend', 'add-me'], Lucide.contactRound),
  (['name', 'username'], Lucide.userRound),
  (['unread', 'notification'], Lucide.bell),
  (['voice', 'call', 'sound'], LucideMore.headphones),
  (['circle', 'space'], Lucide.users),
  (['message', 'chat'], LucideMore.messageCircle),
  // The app's own name (Matt, 2026-11-27: "replace ghost and ghost messaging with Uplink"): a name's tag. Last, so a
  // note that only mentions the app keeps the mark of what it is about; a note named for it ("Uplink: …") is found
  // by its name first.
  (['uplink'], Lucide.tag),
];

/// The notes of each release under its version: each a small tile with its mark, its name in bold where it has one
/// ("Record call:"), and the rest of its words, small.
class WhatsNewList extends StatelessWidget {
  const WhatsNewList({super.key, required this.notes});
  final List<ReleaseNotes> notes;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final gutter = DrawerHead.gutter(t);
    final small = t.fontSize('sm');
    return ListView(
      shrinkWrap: true,
      padding: EdgeInsetsDirectional.fromSTEB(gutter, t.space(3), gutter, t.space(4)),
      children: [
        for (final r in notes) ...[
          if (notes.length > 1) DrawerHeading(r.version),
          for (final line in r.notes)
            Padding(
              padding: EdgeInsets.only(bottom: t.space(3)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  width: 28,
                  height: 28,
                  margin: EdgeInsetsDirectional.only(end: t.space(3)),
                  decoration: BoxDecoration(color: t.color('app-accent').withValues(alpha: 0.14), borderRadius: BorderRadius.circular(8)),
                  alignment: Alignment.center,
                  child: AppIcon(noteIcon(line), size: 15, wash: false, color: t.color('app-accent')),
                ),
                Expanded(child: _NoteWords(line, size: small)),
              ]),
            ),
          SizedBox(height: t.space(2)),
        ],
      ],
    );
  }
}

/// A note's words: its name before a colon in bold, where it starts with one, and the rest as they are.
class _NoteWords extends StatelessWidget {
  const _NoteWords(this.line, {required this.size});
  final String line;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final colon = line.indexOf(': ');
    final named = colon > 0 && colon < 40;
    final plain = pageText(t, size, color: t.color('app-ink-2'), height: 1.4);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text.rich(TextSpan(children: [
        if (named) TextSpan(text: line.substring(0, colon + 1), style: pageText(t, size, weight: 'semibold', color: t.color('app-ink'), height: 1.4)),
        TextSpan(text: named ? line.substring(colon + 1) : line, style: plain),
      ])),
    );
  }
}
