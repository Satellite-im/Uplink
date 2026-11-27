import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../kit/settings_type.dart';
import '../mentions.dart';
import 'dialup/bevel.dart' show isBevelChrome;
import 'markdown_field.dart';
import 'ripple_avatar.dart';

/// Writing mentions in a space's chat (Matt, 2026-11-19: "Add mentions support to spaces and circles with the @user
/// prefix"): the composer's words with the mentions in them ([MentionController]), and the list of people that opens
/// over the composer while an "@…" is being written ([MentionSuggestions]). lib/mentions.dart has the rules.

/// A mention as it is drawn among words: in the accent, a little bolder, on a wash of it.
TextStyle mentionStyle(Tokens t, {Color? on}) {
  final accent = t.color('app-accent');
  // Its wash as tall as its own letters, evenly above and below: at the words' own height (1.4) the line's extra room
  // fell mostly above it (Matt, 2026-11-19: "the mention highlight has too much padding on the top"). The line keeps
  // its height from the words around it.
  return TextStyle(
    color: on ?? accent,
    fontWeight: FontWeight.w600,
    height: 1.2,
    leadingDistribution: TextLeadingDistribution.even,
    background: Paint()..color = accent.withValues(alpha: 0.16),
  );
}

/// The composer's words, and who the "@Name"s in them mean: kept where they are as the words around them are edited,
/// a mention typed into is plain words again, and a backspace into one takes all of it (MentionEdit).
class MentionController extends MarkdownController {
  MentionController({super.text});

  List<Mention> _mentions = const [];

  /// The mentions in [text] now.
  List<Mention> get mentions => _mentions;

  /// How a mention is drawn in the field; none (plain words) until the screen says.
  TextStyle? style;

  @override
  set value(TextEditingValue next) {
    final was = super.value;
    if (_mentions.isNotEmpty && next.text != was.text) {
      final edit = MentionEdit.of(
        _mentions,
        was: was.text,
        now: next.text,
        wasStart: was.selection.isValid ? was.selection.start : null,
        wasEnd: was.selection.isValid ? was.selection.end : null,
        nowCursor: next.selection.isValid && next.selection.isCollapsed ? next.selection.baseOffset : null,
      );
      _mentions = edit.mentions;
      if (edit.text != null) {
        next = TextEditingValue(text: edit.text!, selection: TextSelection.collapsed(offset: edit.cursor!));
      }
    }
    super.value = next;
  }

  @override
  void clear() {
    _mentions = const [];
    super.clear();
  }

  /// [text] put in with its [mentions] (a message being edited), the cursor at its end.
  void load(String text, List<Mention> mentions) {
    _mentions = const [];
    super.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    _mentions = mentions;
  }

  /// The "@…" at the cursor, or null where none is being written.
  MentionQuery? get query {
    final s = selection;
    if (!s.isValid || !s.isCollapsed) return null;
    return MentionQuery.at(text, s.baseOffset, mentions: _mentions);
  }

  /// [p] in [q]'s place: "@Name" and a space, the cursor after it.
  void pick(MentionQuery q, MentionPerson p) {
    final name = MentionPerson.written(p.name);
    if (name.isEmpty || q.end > text.length) return;
    final words = '@$name';
    final before = text.substring(0, q.start), after = text.substring(q.end);
    final space = after.startsWith(' ') ? '' : ' ';
    final by = words.length + space.length - (q.end - q.start);
    final kept = [
      for (final m in _mentions)
        if (m.end <= q.start) m else if (m.start >= q.end) m.moved(by),
      Mention(q.start, words.length, p.id),
    ]..sort((a, b) => a.start.compareTo(b.start));
    // Set as one change, with the mentions as they will be: the edit rule is not asked about it.
    _mentions = const [];
    super.value = TextEditingValue(text: '$before$words$space$after', selection: TextSelection.collapsed(offset: q.start + words.length + space.length));
    _mentions = kept;
    notifyListeners();
  }

  /// [p] put in at the cursor, as if "@" had been written there and they were picked: the menu on someone's mention.
  void mention(MentionPerson p) {
    final s = selection.isValid ? selection : TextSelection.collapsed(offset: text.length);
    final at = s.start;
    final before = text.substring(0, at);
    final lead = before.isEmpty || before.endsWith(' ') || before.endsWith('\n') ? '' : ' ';
    super.value = TextEditingValue(text: '$before$lead@${text.substring(s.end)}', selection: TextSelection.collapsed(offset: at + lead.length + 1));
    final q = MentionQuery(at + lead.length, '');
    _mentions = [for (final m in _mentions) if (m.end <= s.start) m else if (m.start >= s.end) m.moved(lead.length + 1 - (s.end - s.start))];
    pick(q, p);
  }

  // Drawn by MarkdownController, with the formatting markers dimmed (GMFB-35).
  @override
  List<Mention> get drawnMentions => _mentions;

  @override
  TextStyle? get mentionLook => style;
}

/// The people an "@…" finds, in a list over the composer: their face, their name in their role's colour, and their
/// username where they have one. A press, Enter or Tab puts the one chosen in; the arrows move the choice and Escape
/// closes the list ([MentionKeys]).
class MentionSuggestions extends StatelessWidget {
  const MentionSuggestions({super.key, required this.people, required this.chosen, required this.onPick, this.inkOf});
  final List<MentionPerson> people;
  final int chosen;
  final ValueChanged<MentionPerson> onPick;

  /// The colour of someone's name (their role's); the page's ink where null.
  final Color? Function(MentionPerson p)? inkOf;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    final radius = bevel ? 0.0 : t.lenOf('1rem');
    return Semantics(
      container: true,
      label: '${people.length} ${people.length == 1 ? 'person' : 'people'} to mention',
      child: Container(
        key: const ValueKey('mention-suggestions'),
        margin: EdgeInsetsDirectional.fromSTEB(t.space(2), 0, t.space(2), t.space(1)),
        padding: EdgeInsets.symmetric(vertical: t.space(1)),
        decoration: BoxDecoration(
          color: t.color('app-paper'),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: t.color('app-ink-4'), width: 1),
          boxShadow: bevel ? null : [BoxShadow(color: const Color(0x22000000), blurRadius: t.space(4), offset: Offset(0, t.space(1)))],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var i = 0; i < people.length; i++) _row(context, t, people[i], i == chosen, radius),
        ]),
      ),
    );
  }

  Widget _row(BuildContext context, Tokens t, MentionPerson p, bool chosen, double radius) {
    final ink = inkOf?.call(p) ?? t.color('app-ink');
    return GlacierPressable(
      key: ValueKey('mention-${p.id}'),
      // The field keeps the keyboard and the cursor: a press here must not take the focus from it.
      canRequestFocus: false,
      onPressed: () => onPick(p),
      semanticLabel: 'Mention ${p.name}',
      builder: (context, state) => Container(
        margin: EdgeInsets.symmetric(horizontal: t.space(1)),
        padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: t.space(1) + 2),
        decoration: BoxDecoration(
          color: chosen || state.hovered || state.pressed ? t.color('app-paper-2') : null,
          borderRadius: BorderRadius.circular(radius == 0 ? 0 : t.lenOf('0.75rem')),
        ),
        child: Row(children: [
          ExcludeSemantics(child: RippleAvatar(name: p.name, level: 0, size: 26, ringed: false)),
          SizedBox(width: t.space(2)),
          Flexible(child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: ink))),
          if ((p.username ?? '').isNotEmpty) ...[
            SizedBox(width: t.space(2)),
            Flexible(child: Text('@${p.username}', maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3')))),
          ],
          if (p.here) ...[
            SizedBox(width: t.space(2)),
            Text('Here now', style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
          ],
        ]),
      ),
    );
  }
}

/// The keys a computer's keyboard uses on the list while it is open, taken before the field sees them: up and down
/// choose, Enter and Tab put the chosen one in, Escape closes it. Anything else is the field's. Null where the key is
/// not the list's.
KeyEventResult? mentionKey(KeyEvent e, {required int count, required int chosen, required ValueChanged<int> choose, required VoidCallback pick, required VoidCallback close}) {
  if (count == 0 || e is KeyUpEvent) return null;
  final shift = HardwareKeyboard.instance.isShiftPressed;
  switch (e.logicalKey) {
    case LogicalKeyboardKey.arrowDown:
      choose((chosen + 1) % count);
      return KeyEventResult.handled;
    case LogicalKeyboardKey.arrowUp:
      choose((chosen - 1 + count) % count);
      return KeyEventResult.handled;
    case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter:
      if (shift) return null;
      if (e is KeyDownEvent) pick();
      return KeyEventResult.handled;
    case LogicalKeyboardKey.tab:
      if (e is KeyDownEvent) pick();
      return KeyEventResult.handled;
    case LogicalKeyboardKey.escape:
      if (e is KeyDownEvent) close();
      return KeyEventResult.handled;
  }
  return null;
}
