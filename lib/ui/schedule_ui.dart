/// Scheduling a message from Send (lib/scheduled.dart; Matt, 2026-11-20: "Add support for scheduling messages by
/// pressing and holding or right clicking on the send button"): Send's menu, the times offered and a time of one's
/// own, and the strip over a conversation's composer that shows what is waiting there, with Send now and Cancel.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../kit/semantic_colors.dart';
import '../kit/settings_type.dart';
import '../scheduled.dart';
import 'common.dart';
import 'computers.dart' show PairButton;

const _dayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// When a scheduled message goes, said as a person would: "Today, 6:00 PM", "Tomorrow, 9:00 AM", "Monday, 9:00 AM"
/// within the week, else "Nov 30, 9:00 AM".
String scheduleWhen(DateTime d, [DateTime? now]) {
  now ??= Scheduled.now();
  final today = DateTime(now.year, now.month, now.day);
  final ahead = DateTime(d.year, d.month, d.day).difference(today).inDays;
  final day = switch (ahead) {
    0 => 'Today',
    1 => 'Tomorrow',
    < 7 when ahead > 1 => _dayNames[d.weekday - 1],
    _ => '${_months[d.month - 1]} ${d.day}',
  };
  return '$day, ${clock(d)}';
}

/// The times offered first: in an hour, this evening at 6 (before 5), tomorrow at 9, and Monday at 9 (from Friday on).
List<(String, DateTime)> scheduleSuggestions([DateTime? now]) {
  now ??= Scheduled.now();
  final hour = DateTime(now.year, now.month, now.day, now.hour, now.minute).add(const Duration(hours: 1));
  final evening = DateTime(now.year, now.month, now.day, 18);
  final tomorrow = DateTime(now.year, now.month, now.day + 1, 9);
  final monday = DateTime(now.year, now.month, now.day + (DateTime.monday - now.weekday + 7) % 7, 9);
  return [
    ('In 1 hour', hour),
    if (now.hour < 17) ('This evening', evening),
    ('Tomorrow morning', tomorrow),
    if (now.weekday >= DateTime.friday) ('Monday morning', monday.isAfter(tomorrow) ? monday : monday.add(const Duration(days: 7))),
  ];
}

/// Send's menu, pressed and held or right-clicked: Schedule message, where there is something to send and the
/// conversation can be written to later ([to] null where it can't). [onScheduled] clears what was written.
Future<void> openSendMenu(BuildContext context, {required ScheduleTarget? to, required String text, required VoidCallback onScheduled}) async {
  final words = text.trim();
  if (to == null || words.isEmpty) {
    toast(context, to == null ? 'Messages here can\'t be scheduled.' : 'Write something to schedule it.');
    return;
  }
  await showChoices(context, title: 'Send later', choices: [
    for (final (label, at) in scheduleSuggestions()) Choice(label, Lucide.clock, () => _schedule(context, to, words, at, onScheduled), hint: scheduleWhen(at)),
    Choice('Pick a time…', LucideMore.calendarClock, () async {
      final at = await pickScheduleTime(context);
      if (at != null && context.mounted) _schedule(context, to, words, at, onScheduled);
    }),
  ]);
}

void _schedule(BuildContext context, ScheduleTarget to, String words, DateTime at, VoidCallback onScheduled) {
  Scheduled.instance.add(to, words, at);
  onScheduled();
  if (context.mounted) toast(context, 'Scheduled for ${scheduleWhen(at)}');
}

/// A day and a time of one's own: the page's answer, or null where it was left.
Future<DateTime?> pickScheduleTime(BuildContext context, {DateTime? from}) => push<DateTime>(context, (_) => ScheduleTimePage(from: from));

/// The "Pick a time" page: a chip for each of the next eight days, steppers for the hour and for the minutes in
/// fives, and Schedule, which answers with the time chosen and can't be pressed for one that has passed.
class ScheduleTimePage extends StatefulWidget {
  const ScheduleTimePage({super.key, this.from});

  /// Where it starts: a message's own time, when it is moved; else the next hour.
  final DateTime? from;

  @override
  State<ScheduleTimePage> createState() => _ScheduleTimePageState();
}

class _ScheduleTimePageState extends State<ScheduleTimePage> {
  late DateTime _now = Scheduled.now();
  late DateTime _at = widget.from ?? DateTime(_now.year, _now.month, _now.day, _now.hour + 1);

  /// The time chosen so far, moved to [day].
  DateTime _onDay(DateTime day) => DateTime(day.year, day.month, day.day, _at.hour, _at.minute);

  void _step(Duration by) => setState(() => _at = _at.add(by));

  bool get _ahead => _at.isAfter(_now);

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    _now = Scheduled.now();
    final today = DateTime(_now.year, _now.month, _now.day);
    Widget chip(String label, bool on, VoidCallback onPressed, {Key? key}) => GlacierPressable(
          key: key,
          onPressed: onPressed,
          semanticLabel: label,
          builder: (context, state) => Container(
            padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
            decoration: ShapeDecoration(
              color: on ? t.color('app-ink') : const Color(0x00000000),
              shape: StadiumBorder(side: BorderSide(color: on ? t.color('app-ink') : t.color('app-rule'), width: t.len('glacier-hairline'))),
            ),
            child: Text(label, style: pageText(t, t.fontSize('sm'), weight: 'medium', color: on ? t.color('glacier-bg') : t.color('app-ink'))),
          ),
        );
    Widget stepper(String label, String value, VoidCallback less, VoidCallback more, String key) => Row(children: [
          Expanded(child: Text(label, style: pageText(t, t.fontSize('md'), color: t.color('app-ink-2')))),
          IconTap(key: ValueKey('$key-less'), icon: Lucide.minus, label: 'Earlier', onPressed: less),
          SizedBox(width: t.lenOf('5.5rem'), child: Text(value, textAlign: TextAlign.center, style: pageText(t, t.fontSize('lg'), weight: 'semibold', color: t.color('app-ink')))),
          IconTap(key: ValueKey('$key-more'), icon: Lucide.plus, label: 'Later', onPressed: more),
        ]);
    return GhostPage(
      title: 'Pick a time',
      body: ListView(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(3), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
        children: [
          Text('Day', style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: t.color('app-ink-3'))),
          SizedBox(height: t.space(2)),
          Wrap(spacing: t.space(2), runSpacing: t.space(2), children: [
            for (var i = 0; i < 8; i++)
              () {
                final day = today.add(Duration(days: i));
                final label = i == 0 ? 'Today' : i == 1 ? 'Tomorrow' : '${_dayNames[day.weekday - 1].substring(0, 3)} ${day.day}';
                final on = _at.year == day.year && _at.month == day.month && _at.day == day.day;
                return chip(label, on, () => setState(() => _at = _onDay(day)), key: ValueKey('schedule-day-$i'));
              }(),
          ]),
          SizedBox(height: t.space(6)),
          stepper('Hour', clock(_at).split(':').first + (_at.hour < 12 ? ' AM' : ' PM'), () => _step(const Duration(hours: -1)), () => _step(const Duration(hours: 1)), 'schedule-hour'),
          SizedBox(height: t.space(2)),
          stepper('Minutes', ':${_at.minute.toString().padLeft(2, '0')}', () => _step(const Duration(minutes: -5)), () => _step(const Duration(minutes: 5)), 'schedule-minute'),
          SizedBox(height: t.space(6)),
          Text(
            _ahead ? 'Sends ${scheduleWhen(_at, _now)}' : 'That time has passed. Pick a later one.',
            style: pageText(t, t.fontSize('md'), weight: 'medium', color: _ahead ? t.color('app-ink') : t.danger),
          ),
          SizedBox(height: t.space(2)),
          Text('Uplink sends it then if it\'s open, or as soon as it opens.', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
          SizedBox(height: t.space(6)),
          PairButton(key: const ValueKey('schedule-confirm'), label: 'Schedule', icon: Lucide.clock, onPressed: _ahead ? () => Navigator.of(context).pop(_at) : null),
        ],
      ),
    );
  }
}

/// What is waiting to go in this conversation, over its composer: one row each, pressed for Send now, Change the time
/// and Cancel. Nothing at all where nothing waits.
class ScheduledStrip extends StatelessWidget {
  const ScheduledStrip({super.key, required this.to});
  final ScheduleTarget? to;

  @override
  Widget build(BuildContext context) {
    final to = this.to;
    if (to == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Scheduled.instance,
      builder: (context, _) {
        final waiting = Scheduled.instance.forConversation(to.kind, to.target);
        if (waiting.isEmpty) return const SizedBox.shrink();
        final t = context.tokens;
        return Padding(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(1), t.space(3), 0),
          child: Column(mainAxisSize: MainAxisSize.min, children: [for (final m in waiting) _ScheduledRow(message: m)]),
        );
      },
    );
  }
}

/// One waiting message in the strip: when it goes and its first line, or "Not sent" in red for one that is stuck.
class _ScheduledRow extends StatelessWidget {
  const _ScheduledRow({required this.message});
  final ScheduledMessage message;

  Future<void> _menu(BuildContext context) => showChoices(context, title: 'Scheduled for ${scheduleWhen(message.when)}', choices: [
        Choice('Send now', Lucide.send, () async {
          final ok = await Scheduled.instance.sendNow(message.id);
          if (!ok && context.mounted) toast(context, 'Couldn\'t send it just now.', tone: GlacierToastTone.danger);
        }),
        Choice('Change the time', Lucide.clock, () async {
          final at = await pickScheduleTime(context, from: message.when);
          if (at == null) return;
          // A new time is the old one cancelled and the same words scheduled again.
          Scheduled.instance.cancel(message.id);
          Scheduled.instance.add((kind: message.kind, target: message.target, who: message.who), message.text, at);
        }),
        Choice('Cancel', Lucide.x, () => Scheduled.instance.cancel(message.id), danger: true),
      ]);

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final stuck = message.stuck;
    return GlacierPressable(
      key: ValueKey('scheduled-${message.id}'),
      onPressed: () => unawaited(_menu(context)),
      semanticLabel: 'Scheduled for ${scheduleWhen(message.when)}: ${message.text}',
      builder: (context, state) => Container(
        margin: EdgeInsets.only(bottom: t.space(1)),
        padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
        decoration: BoxDecoration(
          color: state.hovered || state.pressed ? t.color('app-rule') : t.color('app-raised'),
          borderRadius: BorderRadius.circular(t.lenOf('0.75rem')),
        ),
        child: Row(children: [
          AppIcon(stuck ? Lucide.circleAlert : Lucide.clock, size: 15, color: stuck ? t.danger : t.color('app-ink-2'), wash: false),
          SizedBox(width: t.space(2)),
          Text(stuck ? 'Not sent' : scheduleWhen(message.when), style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: stuck ? t.danger : t.color('app-ink'))),
          SizedBox(width: t.space(2)),
          Expanded(child: Text(message.text, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2')))),
        ]),
      ),
    );
  }
}
