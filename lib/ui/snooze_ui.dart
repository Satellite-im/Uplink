/// Snoozing one message (GMFB-36, from the Uplink gap review: "Snooze a chat or message until a time; it comes back to
/// the top with a notification"): its menu's Snooze…, with the times a conversation's has (lib/snooze.dart), and the
/// reminder pinned at the top of its conversation once it is back, which shows it.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../kit/settings_type.dart';
import '../snooze.dart';
import 'common.dart';

/// The menu's line that snoozes message [id] in the conversation kept under [chat] (Snoozed.text or Snoozed.space),
/// called [title], with [words] its words for the reminder; or takes its snooze off where it has one.
Choice snoozeMessageChoice(BuildContext context, {required String chat, required String id, required String title, required String words}) {
  final until = Snoozed.instance.messageUntil(chat, id);
  return Choice(until == null ? 'Snooze…' : 'Unsnooze', Lucide.clock, () => unawaited(_snoozeMessage(context, chat: chat, id: id, title: title, words: words)),
      hint: until == null ? null : 'Until ${dayHeading(until)} ${clock(until)}');
}

Future<void> _snoozeMessage(BuildContext context, {required String chat, required String id, required String title, required String words}) async {
  final z = Snoozed.instance;
  if (z.messageUntil(chat, id) != null) {
    z.unsnoozeMessage(chat, id);
    toast(context, 'Snooze taken off');
    return;
  }
  await showChoices(context, title: 'Snooze this message: it comes back pinned at the top of the chat${Snoozed.notifies ? ', with a notification' : ''}.', choices: [
    for (final o in Snoozed.choices(DateTime.now()))
      Choice(o.label, Lucide.clock, () {
        z.snoozeMessage(chat, id, o.at, title: title, words: words);
        toast(context, 'Message snoozed until ${dayHeading(o.at)} ${clock(o.at)}', action: GlacierToastAction(label: 'Undo', onPress: () => z.unsnoozeMessage(chat, id)));
      }),
  ]);
}

/// The messages of the conversation kept under [chat] back from a snooze, pinned at its top: each pressed is shown
/// ([onShow], with its id) and put away; its cross puts it away. Nothing where there are none.
class SnoozedReminders extends StatelessWidget {
  const SnoozedReminders({super.key, required this.chat, required this.onShow});
  final String chat;
  final ValueChanged<String> onShow;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListenableBuilder(
      listenable: Snoozed.instance,
      builder: (context, _) {
        final back = Snoozed.instance.remindersIn(chat);
        if (back.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(2), t.space(3), 0),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final r in back)
              Padding(
                key: ValueKey('snoozed-${r.id}'),
                padding: EdgeInsets.only(bottom: t.space(1)),
                child: GlacierPressable(
                  onPressed: () {
                    Snoozed.instance.dismiss(chat, r.id);
                    onShow(r.id);
                  },
                  semanticLabel: 'Show the snoozed message',
                  builder: (context, state) => Container(
                    padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(2), t.space(1), t.space(2)),
                    decoration: BoxDecoration(
                      color: t.color(state.pressed || state.hovered ? 'app-paper-3' : 'app-paper-2'),
                      borderRadius: BorderRadius.circular(t.radius('md')),
                      border: Border.all(color: t.color('app-rule'), width: t.len('glacier-hairline')),
                    ),
                    child: Row(children: [
                      AppIcon(Lucide.alarmClock, size: 16, color: t.color('app-accent')),
                      SizedBox(width: t.space(2)),
                      Expanded(
                        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('Back from snooze', style: pageText(t, t.fontSize('xs'), weight: 'bold', color: t.color('app-accent'))),
                          Text(r.words.isEmpty ? 'A message' : r.words, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink'))),
                        ]),
                      ),
                      IconTap(icon: Lucide.x, label: 'Put the reminder away', size: 16, box: t.lenOf('2rem'), onPressed: () => Snoozed.instance.dismiss(chat, r.id)),
                    ]),
                  ),
                ),
              ),
          ]),
        );
      },
    );
  }
}

/// Scrolls [controller]'s list (a chat's, drawn bottom up) until the row under [key] is built, then brings it to the
/// middle. Older rows that come in as the list nears its end are waited for a little. Whether it was found.
Future<bool> scrollToShown(ScrollController controller, GlobalKey key, {int steps = 120}) async {
  var stuck = 0;
  for (var i = 0; i < steps; i++) {
    final found = key.currentContext;
    if (found != null && found.mounted) {
      await Scrollable.ensureVisible(found, alignment: 0.5, duration: const Duration(milliseconds: 250), curve: Curves.easeOutCubic);
      return true;
    }
    if (!controller.hasClients) return false;
    final p = controller.position;
    if (p.pixels >= p.maxScrollExtent) {
      // At the oldest end: older ones may be on their way (a conversation reads them a page at a time).
      if (++stuck > 10) return false;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } else {
      stuck = 0;
      controller.jumpTo(math.min(p.pixels + p.viewportDimension * 0.8, p.maxScrollExtent));
    }
    await WidgetsBinding.instance.endOfFrame;
  }
  return false;
}
