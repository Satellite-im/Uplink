/// Replies: replies to choose from over the composer, and reminders to follow up (Matt, 2026-11-14, of the ideas to
/// streamline someone's day: "Smart replies", "Follow-up nudges", and "let's add all of the additional ones to a
/// plugins, some can be grouped into the same plugin"). Its Needs a reply tab was taken out (Matt, 2026-11-16:
/// "Remove the "needs a reply" section and functionality").
///
/// - Replies to choose from: over an empty composer, under a text that waits for an answer, three short replies that
///   fit it (a thank-you, a yes-or-no question, a plan, "where are you"); a press writes one in, to send or change.
/// - Follow up: a message's menu has Remind me, an hour from now, this evening or tomorrow morning; and after a text
///   of yours that promises something ("I'll send the photos tonight") the composer offers a reminder for when it
///   said. The reminder is a notification that opens the conversation.
///
/// - Smarter replies (Matt, 2026-11-26: "add more intelligent auto replies using a very lightweight local AI that
///   summarizes text and whatnot"): where the device has a small model of its own (lib/local_ai.dart: Smart Reply on
///   an Android phone, Apple Intelligence's on a Mac or an iPhone), it reads the conversation's last dozen texts and
///   its three replies take the place of the ones worked out from the words, which show first and stay where it has
///   none. And where a lot came in at once (four texts or more since the person wrote, or one long one), Summarize
///   over the composer says it in a sentence, by the same model.
///
/// All of it is worked out on the device. Nothing is sent anywhere.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../kit/settings_type.dart';
import '../local_ai.dart';
import '../sms.dart';
import '../ui/dialup/dialup.dart';
import '../ui/common.dart';
import 'actions.dart' show whenIn, whenLabel;
import 'conversation.dart' show PluginThread;
import 'plugin.dart';

/// Whether [text] asks something of whoever reads it.
bool asksSomething(String text) {
  final s = text.trim().toLowerCase();
  if (s.isEmpty) return false;
  if (s.contains('?')) return true;
  return RegExp(r'^(?:are|is|can|could|will|would|do|does|did|have|has|should|shall|want|wanna|when|where|what|who|why|how)\b').hasMatch(s) ||
      RegExp(r'(?<![a-z])(?:let me know|lmk|get back to me|text me back|call me back|thoughts\b|rsvp)').hasMatch(s);
}

/// Three replies that fit [text], the shortest first.
List<String> repliesFor(String text) {
  final s = text.trim().toLowerCase();
  bool has(String pattern) => RegExp(pattern).hasMatch(s);
  if (has(r'(?<![a-z])(?:thanks|thank you|thx|ty|appreciate)(?![a-z])')) return const ['You\'re welcome!', 'Anytime 😊', 'No problem'];
  if (has(r'how (?:are|r) (?:you|u)|how\x27s it going|how have you been|what\x27s up|wyd')) return const ['Good, you?', 'Doing well!', 'Busy but good'];
  if (has(r'(?<![a-z])(?:where are you|where r u|eta|how long|how far|almost here|you close)(?![a-z])')) return const ['On my way', '5 minutes away', 'Running late, sorry!'];
  if (has(r'(?<![a-z])(?:call me|can you call|give me a call|ring me)(?![a-z])')) return const ['Calling now', 'Can\'t talk, text me?', 'Call you soon'];
  if (has(r'(?<![a-z])(?:love you|miss you|luv u|ily)(?![a-z])')) return const ['❤️', 'Love you too', 'Miss you too'];
  if (has(r'(?<![a-z])(?:happy birthday|congrats|congratulations)(?![a-z])')) return const ['Thank you! 🎉', 'Thanks so much!', '😊'];
  if (has(r'(?<![a-z])(?:sorry|my bad|apologi)')) return const ['No worries!', 'All good', 'It\'s okay'];
  if (asksSomething(text) && has(r'^(?:are|is|can|could|will|would|do|does|did|have|has|should|want|wanna)\b')) return const ['Yes', 'No', 'Let me check'];
  if (whenIn(text, DateTime.now()) != null && asksSomething(text)) return const ['Sounds good!', 'Works for me', 'Can we do later?'];
  if (asksSomething(text)) return const ['Let me check', 'Not sure', 'I\'ll get back to you'];
  if (whenIn(text, DateTime.now()) != null) return const ['Sounds good!', 'See you then', 'Perfect'];
  return const ['👍', 'Sounds good', 'Haha'];
}

/// What a lot that came in at once says, for the model to sum up: the texts since the person last wrote, where there
/// are [catchUpFewest] or more of them, or the one text where it is [catchUpLong] characters or longer, as the model
/// reads them (`<name>: <words>` a line, or the message alone); null where there is little enough to read.
({String text, bool message, int count})? catchUpOf(List<AiLine> recent) {
  final run = <AiLine>[];
  for (final l in recent.reversed) {
    if (l.mine) break;
    run.add(l);
  }
  if (run.isEmpty) return null;
  if (run.length == 1 || run.length < catchUpFewest) {
    final longest = run.reduce((a, b) => a.text.length >= b.text.length ? a : b);
    return longest.text.length >= catchUpLong ? (text: longest.text, message: true, count: 1) : null;
  }
  return (text: [for (final l in run.reversed) '${l.who.isEmpty ? 'Them' : l.who}: ${l.text.replaceAll('\n', ' ')}'].join('\n'), message: false, count: run.length);
}

const catchUpFewest = 4;
const catchUpLong = 400;

/// When a text of the person's own promises something ("I'll send it tonight", "will call you tomorrow"), and the
/// time it said; null where it promises nothing.
({DateTime at, String label})? promiseIn(String text, DateTime now) {
  final s = text.toLowerCase();
  if (!RegExp(r"(?<![a-z])(?:i['’]ll|i will|will do|i can|let me|i['’]m going to|gonna)(?![a-z])|^(?:will|gonna) ").hasMatch(s.trim())) return null;
  if (!RegExp(r'(?<![a-z])(?:send|call|text|check|look|get back|email|bring|pay|book|ask|find|share|grab|pick up|drop off)').hasMatch(s)) return null;
  final when = whenIn(text, now);
  if (when != null && when.at.isAfter(now)) {
    final at = when.allDay ? DateTime(when.at.year, when.at.month, when.at.day, 9) : when.at.subtract(const Duration(minutes: 15));
    return (at: at.isAfter(now) ? at : when.at, label: whenLabel(when.at, when.allDay, now));
  }
  if (RegExp(r'(?<![a-z])(?:later|soon|in a bit|after work)(?![a-z])').hasMatch(s)) {
    final at = now.add(const Duration(hours: 3));
    return (at: at, label: 'Later');
  }
  return null;
}

/// The times a reminder can be for, from [now]: an hour from now, this evening at six (or tomorrow's, past five),
/// tomorrow morning at nine.
List<({String label, DateTime at})> remindTimes(DateTime now) {
  final evening = now.hour < 17 ? DateTime(now.year, now.month, now.day, 18) : DateTime(now.year, now.month, now.day + 1, 18);
  return [
    (label: 'In an hour', at: now.add(const Duration(hours: 1))),
    (label: now.hour < 17 ? 'This evening' : 'Tomorrow evening', at: evening),
    (label: 'Tomorrow morning', at: DateTime(now.year, now.month, now.day + 1, 9)),
  ];
}

class RepliesPlugin extends GhostPlugin {
  const RepliesPlugin({this.now});
  final DateTime Function()? now;

  @override
  String get id => 'replies';

  @override
  String get name => 'Replies';

  @override
  String get description => 'Replies to choose from over the composer, smarter where the device has a small AI model of its own, and reminders to follow up.';

  @override
  LucideIcon get icon => LucideMore.reply;

  // Its card and page on the Plugins page (Matt, 2026-11-17: "redo how the plugins look with their own dedicated plugins page
  // with a marketplace like look how ghostmd has").
  @override
  PluginShelf get shelf => PluginShelf.messages;

  // Its tags in the Marketplace, so a search by tag finds it beside the plugins from other developers (Matt, 2026-11-20:
  // "plugin tags").
  @override
  List<String> get labels => const ['replies'];

  @override
  String get tagline => 'Replies to choose from, and reminders to follow up.';

  @override
  List<String> get adds => const [
        'Three short replies over the composer, under a text that waits for an answer',
        'Replies that read the conversation, and Summarize when a lot came in, by the device\'s own small AI model',
        'Remind me, in a message\'s menu',
      ];

  @override
  List<PluginReach> get reaches => const [PluginReach(Lucide.messageSquare, 'The words of the conversation on the screen', 'Worked out on this device, by its own model where it has one. Nothing is sent anywhere.')];

  DateTime _now() => (now ?? DateTime.now)();

  /// Asks the phone to remind the person at [at] to follow up in [thread], and says whether it will ([when] is the
  /// time in words).
  static Future<void> _remind(PluginHost host, int thread, String who, String words, DateTime at, String when) async {
    final ok = await Sms.instance.remind(thread: thread, title: 'Follow up${who.isEmpty ? '' : ' with $who'}', body: words, at: at);
    host.say(ok ? 'I\'ll remind you ${when.toLowerCase()}' : 'Couldn\'t set the reminder');
  }

  @override
  List<SlotFill> get slots => [
        // Over the composer: replies to choose from, or a reminder after a promise.
        Slots.aboveComposer.fill((context, place, prefs) {
          if (place.text.isNotEmpty) return const [];
          final last = place.lastIn;
          if (last != null && prefs.flag('suggest') && last.trim().isNotEmpty) {
            final smart = prefs.flag('smart');
            final newest = place.recent.isEmpty ? null : place.recent.last;
            return [
              SmartReplyChips(
                key: ValueKey('replies:${place.thread}:${newest?.at}:${last.hashCode}'),
                rules: repliesFor(last),
                recent: smart ? place.recent : const [],
                catchUp: smart ? catchUpOf(place.recent) : null,
              ),
            ];
          }
          final mine = place.lastOut;
          if (mine != null && prefs.flag('nudge') && !Sms.remote) {
            final promise = promiseIn(mine, _now());
            if (promise != null) return [_PromiseChip(thread: place.thread, who: place.title, words: mine, at: promise.at, label: promise.label)];
          }
          return const [];
        }),
        // A message's menu: Remind me.
        Slots.messageMenu.fill((place, prefs) => Sms.remote || !prefs.flag('nudge')
            ? const []
            : [
                for (final t in remindTimes(_now()))
                  PluginAction(
                    label: 'Remind me ${t.label.toLowerCase()}',
                    icon: Lucide.bell,
                    run: (host) => _remind(host, place.facts.thread, '', place.facts.text, t.at, t.label),
                  ),
              ]),
      ];

  @override
  PluginSettingsPage? get settingsPage => PluginSettingsPage(
        hue: 'blue',
        intro: 'Keeping up with the people waiting on you.',
        summary: (prefs) => [if (prefs.flag('suggest')) prefs.flag('smart') ? 'Smart suggestions' : 'Suggestions', if (prefs.flag('nudge')) 'Reminders'].join(' · '),
      );

  @override
  List<PluginSetting> get settings => const [
        PluginSetting.toggle(key: 'suggest', label: 'Replies to choose from', hint: 'Three short replies over the composer, under a text that waits for an answer.', icon: Lucide.messageSquare),
        PluginSetting.toggle(key: 'nudge', label: 'Reminders to follow up', hint: 'Remind me in a message\'s menu, and an offer after a text of yours that promises something.', icon: Lucide.bell),
        PluginSetting.toggle(
          key: 'smart',
          label: 'Smarter replies and summaries',
          hint: 'Where this device has a small AI model of its own (Smart Reply on Android, Apple Intelligence on a Mac or an iPhone), replies that read the conversation, and Summarize when a lot came in.',
          icon: Lucide.sparkles,
        ),
        PluginSetting.note(label: 'On this device only', hint: 'Worked out on the device, by its own model where it has one. Nothing is sent anywhere.', icon: Lucide.lock),
      ];
}

/// One of the rounded chips over the composer.
Widget replyChip(BuildContext context, String label, VoidCallback? onPressed, {LucideIcon? icon, String? semantic}) {
  final t = context.tokens;
  // Under the bevelled chrome (Dial-Up, Runestone) a reply is a push button like the rest of its window's, and so is
  // drawn from a resource pack's own button where the look has one (Matt, 2026-11-27, with a picture of three flat
  // ones: "these responses are not themed pixelated").
  if (isBevelChrome(t)) return RetroButton(onPressed: onPressed, label: label, icon: icon, semanticLabel: semantic ?? 'Reply: $label', faceHeight: 36);
  return GlacierPressable(
    onPressed: onPressed,
    semanticLabel: semantic ?? 'Reply: $label',
    builder: (context, state) => Container(
      padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(1) + 3),
      decoration: BoxDecoration(
        color: t.color(state.pressed ? 'app-paper-3' : 'app-paper-2'),
        borderRadius: BorderRadius.circular(t.radius('full')),
        border: Border.all(color: t.color('app-rule')),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[AppIcon(icon, size: 14, strokeWidth: 2.2, wash: false, color: t.color('app-ink-2')), SizedBox(width: t.space(1) + 2)],
        Text(label, style: pageText(t, t.fontSize('sm'), weight: 'medium', color: t.color('app-ink'))),
      ]),
    ),
  );
}

/// Replies to choose from: a press writes one into the composer.
class ReplyChips extends StatelessWidget {
  const ReplyChips({super.key, required this.replies, this.lead = const []});
  final List<String> replies;

  /// What goes before the replies (Summarize).
  final List<Widget> lead;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final thread = PluginThread.of(context);
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(2), t.space(3), t.space(2)),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final w in lead) ...[w, SizedBox(width: t.space(2))],
          for (final r in replies) ...[
            replyChip(context, r, thread == null ? null : () => thread.write(r)),
            SizedBox(width: t.space(2)),
          ],
        ]),
      ),
    );
  }
}

/// The replies worked out from the words at once, and the device's model's in their place once it has them
/// ([recent] is what it reads; empty for none); with Summarize before them where a lot came in ([catchUp]) and the
/// model can sum it up, and the summary over them once pressed.
class SmartReplyChips extends StatefulWidget {
  const SmartReplyChips({super.key, required this.rules, this.recent = const [], this.catchUp});
  final List<String> rules;
  final List<AiLine> recent;
  final ({String text, bool message, int count})? catchUp;

  @override
  State<SmartReplyChips> createState() => _SmartReplyChipsState();
}

class _SmartReplyChipsState extends State<SmartReplyChips> {
  LocalAi get _ai => LocalAi.instance;
  List<String>? _smart;
  bool _canSum = false;
  bool _summing = false;
  String? _summary;
  bool _shut = false;

  @override
  void initState() {
    super.initState();
    if (widget.recent.isNotEmpty) {
      unawaited(_ai.replies(widget.recent).then((r) {
        if (mounted && r != null && r.isNotEmpty) setState(() => _smart = r);
      }));
    }
    if (widget.catchUp != null) {
      unawaited(_ai.status().then((s) {
        if (mounted && s == 'available') setState(() => _canSum = true);
      }));
    }
  }

  Future<void> _sum() async {
    final c = widget.catchUp;
    if (c == null || _summing) return;
    setState(() => _summing = true);
    final said = await _ai.summarize(c.text, message: c.message);
    if (!mounted) return;
    setState(() {
      _summing = false;
      _summary = said;
    });
    if (said == null) toast(context, 'Couldn\'t sum that up');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = widget.catchUp;
    final summary = _summary;
    final replies = _smart ?? widget.rules;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (summary != null && !_shut)
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(2), t.space(3), 0),
          child: Container(
            padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(2), t.space(1), t.space(2)),
            decoration: BoxDecoration(
              color: t.color('app-paper-2'),
              borderRadius: BorderRadius.circular(t.radius('lg')),
              border: Border.all(color: t.color('app-rule')),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(top: 2), child: AppIcon(Lucide.sparkles, size: 14, strokeWidth: 2.2, wash: false, color: t.color('app-ink-2'))),
              SizedBox(width: t.space(2)),
              Expanded(
                child: Semantics(
                  label: 'Summary',
                  child: Text(summary, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink'))),
                ),
              ),
              IconTap(icon: Lucide.x, label: 'Close the summary', size: 14, onPressed: () => setState(() => _shut = true)),
            ]),
          ),
        ),
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: ReplyChips(
          key: ValueKey(replies.join('\u0000')),
          replies: replies,
          lead: [
            if (c != null && _canSum && summary == null)
              replyChip(context, _summing ? 'Summing up…' : c.message ? 'Summarize' : 'Summarize ${c.count} messages', _summing ? null : _sum, icon: Lucide.sparkles, semantic: 'Summarize what came in'),
          ],
        ),
      ),
    ]);
  }
}

/// After a text of the person's that promises something: a reminder for when it said.
class _PromiseChip extends StatelessWidget {
  const _PromiseChip({required this.thread, required this.who, required this.words, required this.at, required this.label});
  final int thread;
  final String who;
  final String words;
  final DateTime at;
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(2), t.space(3), t.space(2)),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: GlacierPressable(
          onPressed: () async {
            final ok = await Sms.instance.remind(thread: thread, title: 'Follow up${who.isEmpty ? '' : ' with $who'}', body: words, at: at);
            if (context.mounted) toast(context, ok ? 'I\'ll remind you' : 'Couldn\'t set the reminder');
          },
          builder: (context, state) => Container(
            padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(1) + 3),
            decoration: BoxDecoration(
              color: t.color(state.pressed ? 'app-paper-3' : 'app-paper-2'),
              borderRadius: BorderRadius.circular(t.radius('full')),
              border: Border.all(color: t.color('app-rule')),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              AppIcon(Lucide.bell, size: 14, strokeWidth: 2.2, wash: false, color: t.color('app-ink-2')),
              SizedBox(width: t.space(1) + 2),
              Text('You promised something · remind me ${label == 'Later' ? 'later' : label}', style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: t.color('app-ink'))),
            ]),
          ),
        ),
      ),
    );
  }
}
