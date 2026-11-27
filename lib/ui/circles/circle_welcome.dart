/// Welcome messages, the welcome space, the system space and read-only spaces on the screen (Matt, 2026-11-20: "add -
/// Welcome messages for new members and allow setting a "welcome" channel as well as read only channels for system
/// messages and admin / moderation announcements"; lib/circles/welcome.dart): Circle settings › Welcome, and what a
/// space's chat shows of them (the welcome card at its top, the system space's lines, the footer of a read-only space).
library;

import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter, TextCapitalization, TextInputType;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../circles/circles.dart';
import '../../kit/semantic_colors.dart';
import '../../kit/settings_kit.dart';
import '../../kit/settings_type.dart';
import '../../voice/voice.dart' show SpaceKind, VoiceChannel;
import '../common.dart';
import '../../l10n/words.dart';

/// Circle settings › Welcome: the welcome's words, the space newcomers land in, the system space, and which spaces are
/// read-only. [onOpenSpace] opens a space's own settings (where it is made read-only).
List<Widget> circleWelcomeSection(BuildContext context, Circle c, {required ValueChanged<String> onOpenSpace}) {
  final t = context.tokens;
  final circles = Circles.instance;
  final m = c.manifest;
  final edit = circles.can(c, CirclePerm.circle);
  final editSpaces = circles.can(c, CirclePerm.spaces);
  final text = m.welcomeText;
  final welcome = m.welcomeSpace;
  final system = m.systemSpace;
  final gap = SizedBox(height: t.space(6));
  String spaceName(String? seed) => seed == null ? 'None' : '# ${c.space(seed)?.name ?? ''}';
  final chats = [for (final s in c.manifest.ordered) if (s.kind != SpaceKind.files) s];
  final readOnly = [for (final s in c.manifest.ordered) if (readOnlyOf(s)) s];
  void failed() => toast(context, 'Couldn\'t change the circle', tone: GlacierToastTone.danger);

  return [
    if (!edit) ...[SettingsCallout(child: Text('Whoever has Change the circle sets ${c.name}\'s welcome.')), SizedBox(height: t.space(4))],
    PaneSection(
      title: 'Welcome message',
      description: const Tr('Shown to each new member at the top of the welcome space, which the circle opens on for them. Write {name} where their name goes.'),
      children: [
        SettingRow(
          key: const ValueKey('circle-welcome-text'),
          icon: AppIcon(Lucide.doorOpen, size: 18),
          label: text.isEmpty ? 'Write a welcome' : 'Welcome message',
          hint: text.isEmpty ? null : Text(text, maxLines: 3, overflow: TextOverflow.ellipsis),
          onPress: edit
              ? () => push<void>(context, (_) => CircleWelcomeWords(
                    initial: text,
                    then: (words) async {
                      final have = circles.bySeed(c.seed) ?? c;
                      if (!await circles.setWelcome(have, text: words, space: have.manifest.welcomeSpace) && context.mounted) failed();
                    },
                  ))
              : null,
        ),
        SettingRow(
          key: const ValueKey('circle-welcome-space'),
          icon: AppIcon(Lucide.messageSquare, size: 18),
          label: 'Welcome space',
          hint: const Tr('Where new members land, and where the welcome is shown'),
          value: Text(spaceName(welcome)),
          onPress: edit
              ? () => showChoices(context, title: 'Where do new members land?', choices: [
                    Choice('None', welcome == null ? Lucide.check : Lucide.x, () => circles.setWelcome(circles.bySeed(c.seed) ?? c, text: text, space: null)),
                    for (final s in chats) Choice('# ${s.name}', s.seed == welcome ? Lucide.check : Lucide.messageSquare, () => circles.setWelcome(circles.bySeed(c.seed) ?? c, text: text, space: s.seed)),
                  ])
              : null,
        ),
      ],
    ),
    gap,
    PaneSection(
      title: 'System messages',
      description: const Tr('A read-only space where each member\'s app writes who joined, who was kicked or banned and who became or stopped being an admin. Only the owner and admins post there, so it suits announcements too.'),
      children: [
        SettingRow(
          key: const ValueKey('circle-system-space'),
          icon: AppIcon(Lucide.scrollText, size: 18),
          label: 'System space',
          value: Text(spaceName(system)),
          onPress: edit && editSpaces
              ? () => showChoices(context, title: 'Where are system messages written?', choices: [
                    Choice('None', system == null ? Lucide.check : Lucide.x, () => circles.setSystemSpace(circles.bySeed(c.seed) ?? c, null)),
                    for (final s in chats)
                      Choice('# ${s.name}', s.seed == system ? Lucide.check : Lucide.scrollText, () => circles.setSystemSpace(circles.bySeed(c.seed) ?? c, s.seed), hint: readOnlyOf(s) ? null : 'It becomes read-only'),
                  ])
              : null,
        ),
      ],
    ),
    gap,
    PaneSection(
      title: 'Read-only spaces · ${readOnly.length}',
      description: const Tr('Only the owner and admins can post in these: announcements, rules, system messages. The relay holds everyone else to it too. Make a space read-only in its settings.'),
      children: [
        if (readOnly.isEmpty) const SettingRowBox(child: Tr('None yet.')),
        for (final s in readOnly)
          SettingRow(
            key: ValueKey('circle-readonly-${s.seed}'),
            icon: AppIcon(Lucide.lock, size: 18),
            label: '# ${s.name}',
            hint: s.seed == system ? const Tr('System messages') : (s.seed == welcome ? const Tr('Welcome space') : null),
            onPress: editSpaces ? () => onOpenSpace(s.seed) : null,
          ),
      ],
    ),
  ];
}

/// Writing a circle's welcome: a few lines, with {name} for the newcomer's.
class CircleWelcomeWords extends StatefulWidget {
  const CircleWelcomeWords({super.key, required this.initial, required this.then});
  final String initial;
  final void Function(String words) then;

  @override
  State<CircleWelcomeWords> createState() => _CircleWelcomeWordsState();
}

class _CircleWelcomeWordsState extends State<CircleWelcomeWords> {
  late final _words = TextEditingController(text: widget.initial);
  final _focus = FocusNode();

  @override
  void dispose() {
    _words.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Hands the words back, trimmed (empty for no welcome), and closes the page.
  void _done() {
    widget.then(_words.text.trim());
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final ink = pageText(t, t.fontSize('md'), color: t.color('app-ink'));
    return GhostPage(
      title: 'Welcome message',
      body: ListView(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8)),
        children: [
          PaneSection(
            description: const Tr('Each new member sees this at the top of the welcome space. {name} is their name. Leave it empty for none.'),
            children: [
              SettingRowBox(
                child: GestureDetector(
                  onTap: _focus.requestFocus,
                  child: Container(
                    constraints: BoxConstraints(minHeight: t.lenOf('7rem')),
                    padding: EdgeInsets.all(t.space(3)),
                    decoration: BoxDecoration(color: t.color('app-paper-3'), borderRadius: BorderRadius.circular(t.radius('md'))),
                    child: Stack(children: [
                      ListenableBuilder(
                        listenable: _words,
                        builder: (context, _) => _words.text.isEmpty
                            ? IgnorePointer(child: Tr('Welcome, {name}! Say hello in # general, and read # rules first.', style: ink.copyWith(color: t.color('app-ink-3'))))
                            : const SizedBox.shrink(),
                      ),
                      EditableText(
                        key: const ValueKey('circle-welcome-field'),
                        controller: _words,
                        focusNode: _focus,
                        autofocus: true,
                        style: ink,
                        cursorColor: t.color('app-ink'),
                        backgroundCursorColor: t.color('app-ink-3'),
                        selectionColor: t.textSelection,
                        minLines: 4,
                        maxLines: 12,
                        inputFormatters: [LengthLimitingTextInputFormatter(circleWelcomeMax)],
                        keyboardType: TextInputType.multiline,
                        textCapitalization: TextCapitalization.sentences,
                      ),
                    ]),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: t.space(4)),
          PaneSection(children: [SettingRow(key: const ValueKey('circle-welcome-save'), icon: AppIcon(Lucide.check, size: 18), label: 'Save', onPress: _done)]),
        ],
      ),
    );
  }
}

/// At the top of the welcome space's chat: the circle's welcome, addressed to whoever reads it ([name]).
class CircleWelcomeCard extends StatelessWidget {
  const CircleWelcomeCard({super.key, required this.circle, required this.name});
  final Circle circle;
  final String name;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final words = welcomeFor(circle.manifest.welcomeText, name);
    return Container(
      key: const ValueKey('circle-welcome-card'),
      margin: EdgeInsetsDirectional.fromSTEB(0, t.space(3), 0, t.space(3)),
      padding: EdgeInsets.all(t.space(4)),
      decoration: BoxDecoration(
        color: t.color('app-paper-2'),
        borderRadius: BorderRadius.circular(t.radius('lg')),
        border: Border.all(color: t.color('app-rule')),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          AppIcon(Lucide.doorOpen, size: 18, color: t.color('app-accent')),
          SizedBox(width: t.space(2)),
          Expanded(child: Text('Welcome to ${circle.name}', maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'bold', color: t.color('app-ink')))),
        ]),
        if (words.isNotEmpty) ...[
          SizedBox(height: t.space(2)),
          Text(words, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'))),
        ],
      ]),
    );
  }
}

/// One of the system space's lines: who joined, was removed, became or stopped being an admin.
class CircleSystemLine extends StatelessWidget {
  const CircleSystemLine({super.key, required this.note});
  final CircleSystemNote note;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final icon = switch (note.kind) {
      SystemNoteKind.joined => Lucide.userPlus,
      SystemNoteKind.removed || SystemNoteKind.kicked => Lucide.userMinus,
      SystemNoteKind.admin => Lucide.shieldCheck,
      SystemNoteKind.unadmin => Lucide.shieldCheck,
    };
    final at = DateTime.fromMillisecondsSinceEpoch(note.at);
    final time = '${at.hour}:${at.minute.toString().padLeft(2, '0')}';
    return Padding(
      key: ValueKey('system-note-${note.kind.wire}-${note.id}-${note.at}'),
      padding: EdgeInsets.symmetric(vertical: t.space(1) + 2),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        AppIcon(icon, size: 13, color: t.color('app-ink-3')),
        SizedBox(width: t.space(1) + 2),
        Flexible(child: Text(note.line, maxLines: 2, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: t.color('app-ink-2')))),
        SizedBox(width: t.space(2)),
        Text(time, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
      ]),
    );
  }
}

/// In a read-only space's foot, in the box's place for whoever may not post there.
class ReadOnlyFoot extends StatelessWidget {
  const ReadOnlyFoot({super.key, required this.space, this.system = false});
  final VoiceChannel space;
  final bool system;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      key: const ValueKey('read-only-foot'),
      padding: EdgeInsets.symmetric(vertical: t.space(2)),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        AppIcon(Lucide.lock, size: 14, color: t.color('app-ink-3')),
        SizedBox(width: t.space(1) + 2),
        Flexible(
          child: Text(
            system ? 'System messages. Only admins can post in # ${space.name}.' : 'Only admins can post in # ${space.name}.',
            textAlign: TextAlign.center,
            style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3')),
          ),
        ),
      ]),
    );
  }
}

/// Over the box in a read-only space, for an admin who may post there: that everyone else only reads.
class ReadOnlyAdminLine extends StatelessWidget {
  const ReadOnlyAdminLine({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      key: const ValueKey('read-only-admin'),
      padding: EdgeInsetsDirectional.fromSTEB(t.space(3), 0, t.space(3), t.space(1)),
      child: Row(children: [
        AppIcon(Lucide.megaphone, size: 13, color: t.color('app-ink-3')),
        SizedBox(width: t.space(1) + 2),
        Expanded(child: Text('Read-only: only admins post here, everyone else reads', style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3')))),
      ]),
    );
  }
}
