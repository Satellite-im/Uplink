import 'dart:math' as math;

import 'package:flutter/services.dart' show HapticFeedback, TextCapitalization;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../voice/hangout.dart';
import 'common.dart';
import '../l10n/words.dart';

// Polls in a space's chat (Matt, 2026-11-19: "add Polls as a default feature"; lib/voice/polls.dart): the card a poll
// is shown as, and the page one is asked from.

/// A poll in the chat: its question, each answer with how many chose it on a bar of its share, a mark on what you
/// chose, and how many voted. A press on an answer votes for it (and on yours again takes it back); where more than
/// one may be chosen each is ticked or not on its own.
class PollCard extends StatelessWidget {
  const PollCard({super.key, required this.room, required this.message, required this.maxWidth});
  final HangoutRoom room;
  final HangoutMessage message;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final spec = message.poll!;
    return ListenableBuilder(
      listenable: room,
      builder: (context, _) {
        final tally = room.tally(message);
        final may = room.mayWrite;
        final ink = t.color('app-ink');
        final soft = t.color('app-ink-3');
        void press(int i) {
          final mine = tally.mine;
          final next = spec.multi ? (mine.contains(i) ? [for (final c in mine) if (c != i) c] : [...mine, i]) : (mine.contains(i) ? <int>[] : [i]);
          HapticFeedback.selectionClick();
          room.vote(message, next);
        }

        return Container(
          key: ValueKey('poll-${message.id}'),
          constraints: BoxConstraints(maxWidth: math.min(maxWidth, t.lenOf('24rem'))),
          padding: EdgeInsets.all(t.space(3)),
          decoration: BoxDecoration(color: t.color('app-paper-2'), borderRadius: BorderRadius.circular(t.radius('lg')), border: Border.all(color: t.color('app-rule'))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              AppIcon(LucideMore.chartColumn, size: 14, color: soft),
              SizedBox(width: t.space(1) + 2),
              Text(spec.multi ? 'Poll · choose any' : 'Poll · choose one', style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: soft)),
            ]),
            SizedBox(height: t.space(2)),
            Text(message.text, style: pageText(t, t.fontSize('md'), weight: 'semibold', color: ink, height: 1.3)),
            SizedBox(height: t.space(3)),
            for (final (i, option) in spec.options.indexed) ...[
              _Answer(
                key: ValueKey('poll-${message.id}-option-$i'),
                words: option,
                count: tally.counts[i],
                share: tally.share(i),
                chosen: tally.mine.contains(i),
                multi: spec.multi,
                onPress: may ? () => press(i) : null,
              ),
              if (i < spec.options.length - 1) SizedBox(height: t.space(2)),
            ],
            SizedBox(height: t.space(3)),
            Text(
              tally.voters == 0 ? 'No votes yet' : '${tally.voters} ${tally.voters == 1 ? 'vote' : 'votes'}',
              key: ValueKey('poll-${message.id}-voters'),
              style: pageText(t, t.fontSize('xs'), color: soft),
            ),
          ]),
        );
      },
    );
  }
}

/// One answer of a poll: its words and count over a bar of its [share] (0 to 1), marked where it is yours.
class _Answer extends StatelessWidget {
  const _Answer({super.key, required this.words, required this.count, required this.share, required this.chosen, required this.multi, this.onPress});
  final String words;
  final int count;
  final double share;
  final bool chosen;
  final bool multi;
  final VoidCallback? onPress;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final accent = t.color('app-accent');
    final ink = t.color('app-ink');
    final radius = BorderRadius.circular(t.radius('md'));
    return Semantics(
      button: onPress != null,
      selected: chosen,
      label: '$words, $count ${count == 1 ? 'vote' : 'votes'}',
      excludeSemantics: true,
      child: GlacierPressable(
        onPressed: onPress,
        builder: (context, state) => Container(
          constraints: BoxConstraints(minHeight: t.lenOf('2.5rem')),
          decoration: BoxDecoration(
            color: t.color('app-paper'),
            borderRadius: radius,
            border: Border.all(color: chosen ? accent : t.color('app-rule'), width: chosen ? 1.5 : 1),
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(children: [
              // Its share of the votes, as a wash from the left.
              Positioned.fill(
                child: FractionallySizedBox(
                  alignment: AlignmentDirectional.centerStart,
                  widthFactor: share.clamp(0, 1),
                  child: ColoredBox(color: accent.withValues(alpha: chosen ? 0.22 : 0.12)),
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
                child: Row(children: [
                  _Mark(chosen: chosen, multi: multi),
                  SizedBox(width: t.space(2)),
                  Expanded(child: Text(words, style: pageText(t, t.fontSize('sm'), weight: chosen ? 'semibold' : 'medium', color: ink))),
                  SizedBox(width: t.space(2)),
                  Text('${(share * 100).round()}%', style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: t.color('app-ink-2'))),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A round mark for one answer, a square for any number; filled with a tick where chosen.
class _Mark extends StatelessWidget {
  const _Mark({required this.chosen, required this.multi});
  final bool chosen;
  final bool multi;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final accent = t.color('app-accent');
    return Container(
      width: 18,
      height: 18,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: chosen ? accent : null,
        shape: multi ? BoxShape.rectangle : BoxShape.circle,
        borderRadius: multi ? BorderRadius.circular(4) : null,
        border: Border.all(color: chosen ? accent : t.color('app-ink-3'), width: 1.5),
      ),
      child: chosen ? AppIcon(Lucide.check, size: 12, color: t.color('app-paper')) : null,
    );
  }
}

/// The page a poll is asked from: the question, two answers to start and more up to ten, and whether more than one may
/// be chosen. Asking it sends it into [room] and comes back to the chat.
class NewPollScreen extends StatefulWidget {
  const NewPollScreen({super.key, required this.room});
  final HangoutRoom room;

  @override
  State<NewPollScreen> createState() => _NewPollScreenState();
}

class _NewPollScreenState extends State<NewPollScreen> {
  final _question = TextEditingController();
  final _answers = [TextEditingController(), TextEditingController()];
  bool _multi = false;

  @override
  void initState() {
    super.initState();
    _question.addListener(_changed);
    for (final a in _answers) {
      a.addListener(_changed);
    }
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _question.dispose();
    for (final a in _answers) {
      a.dispose();
    }
    super.dispose();
  }

  PollSpec? get _spec => PollSpec.of([for (final a in _answers) a.text], multi: _multi);

  bool get _ready => _question.text.trim().isNotEmpty && _spec != null;

  void _add() {
    if (_answers.length >= PollSpec.most) return;
    setState(() => _answers.add(TextEditingController()..addListener(_changed)));
  }

  void _ask() {
    final spec = _spec;
    if (!_ready || spec == null) return;
    if (!widget.room.sendPoll(_question.text, spec)) {
      toast(context, 'Couldn\'t ask the poll here.', tone: GlacierToastTone.danger);
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final gap = SizedBox(height: t.space(5));
    return GhostPage(
      title: 'New poll',
      body: SettingsPaneScope(
        finder: SettingsFinder(),
        child: LayoutBuilder(builder: (context, box) {
          final side = math.max(t.space(4), (box.maxWidth - 640) / 2);
          return ListView(padding: EdgeInsetsDirectional.fromSTEB(side, t.space(2), side, t.space(8) + MediaQuery.paddingOf(context).bottom), children: [
            PaneSection(title: 'Question', children: [
              SettingRowBox(
                child: GlacierInput(
                  key: const ValueKey('poll-question'),
                  controller: _question,
                  placeholder: 'Ask something'.t,
                  ariaLabel: 'Question',
                  autoFocus: true,
                  autoCapitalize: TextCapitalization.sentences,
                  maxLength: PollSpec.questionMost,
                ),
              ),
            ]),
            gap,
            PaneSection(title: 'Answers', children: [
              for (final (i, a) in _answers.indexed)
                SettingRowBox(
                  child: GlacierInput(
                    key: ValueKey('poll-answer-$i'),
                    controller: a,
                    placeholder: 'Answer ${i + 1}',
                    ariaLabel: 'Answer ${i + 1}',
                    autoCapitalize: TextCapitalization.sentences,
                    maxLength: PollSpec.optionMost,
                  ),
                ),
              if (_answers.length < PollSpec.most)
                SettingRow(key: const ValueKey('poll-add-answer'), icon: AppIcon(Lucide.plus, size: 18), label: 'Add an answer', onPress: _add),
            ]),
            gap,
            PaneSection(children: [
              SettingRow(
                label: 'Let people choose more than one',
                control: GlacierSwitch(key: const ValueKey('poll-multi'), checked: _multi, onCheckedChange: (v) => setState(() => _multi = v), ariaLabel: 'Let people choose more than one'),
              ),
            ]),
            gap,
            PaneSection(children: [
              SettingRow(
                key: const ValueKey('poll-ask'),
                icon: AppIcon(Lucide.check, size: 18),
                label: 'Ask',
                hint: Text(_ready ? 'Everyone here can vote.' : 'Write a question and at least two answers.'),
                disabled: !_ready,
                onPress: _ready ? _ask : null,
              ),
            ]),
          ]);
        }),
      ),
    );
  }
}
