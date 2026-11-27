import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../app_state.dart';
import '../emoji_data.dart';
import '../emoji_shortcodes.dart';
import '../kit/settings_type.dart';
import 'dialup/bevel.dart' show isBevelChrome;
import 'mention_field.dart' show mentionKey;

/// Emoji by shortcode in every composer (GMFB-22, Matt, Mac 0.12.6: "typing :joy: or something should expand the emoji
/// to the joy emoji and auto suggest with a popup"): a whole ":joy:" becomes 😂 as its closing colon is typed, and while
/// a ":jo" is being written the emoji it finds are offered over the box, as the people an "@…" finds are in a space's
/// chat (lib/ui/mention_field.dart), with the same keys: up and down choose, Enter or Tab puts the chosen one in (Enter
/// does not send while the list is open), Escape closes it, and a press puts that one in. lib/emoji_shortcodes.dart
/// has the rules.
///
/// A screen makes one for its box's controller ([EmojiShortcodeSuggester]), asks it first about each key its field's
/// focus node is given ([EmojiShortcodeSuggester.key]), and draws [EmojiSuggestions] over the box.
class EmojiShortcodeSuggester extends ChangeNotifier {
  EmojiShortcodeSuggester(this.controller, {this.app}) : _was = controller.value {
    controller.addListener(_changed);
  }

  final TextEditingController controller;

  /// The person's choices, for the emoji they used lately (first among equals) and to count the one picked as used.
  final AppState? Function()? app;

  /// The controller's value before the last change, for telling a colon just typed from one that was there.
  TextEditingValue _was;

  /// True while this writes an emoji into the controller, so its own change is not read as typing.
  bool _busy = false;

  /// Whether the emoji's names were asked for, so they are loaded once.
  bool _asked = false;

  ShortcodeQuery? _query;
  List<ShortcodeMatch> _found = const [];
  int _chosen = 0;

  /// The query Escape closed the list on: it stays closed until the query changes.
  ShortcodeQuery? _closedOn;

  /// Whether the list is open.
  bool get open => _query != null && _found.isNotEmpty;
  List<ShortcodeMatch> get found => open ? _found : const [];
  int get chosen => _chosen;

  List<String> _recent() {
    final a = app?.call();
    return a == null ? const [] : EmojiChoices(a).recent;
  }

  /// The words changed or the cursor moved: a ":name:" just closed is put in as its emoji, and the list is found again.
  void _changed() {
    if (_busy) return;
    final was = _was, now = controller.value;
    _was = now;
    final s = now.selection;
    final cursor = s.isValid && s.isCollapsed ? s.baseOffset : -1;
    // The list of names is read from the app's assets the first time a colon is written before letters.
    final data = EmojiData.loaded;
    if (data == null) {
      if (!_asked && cursor > 0 && now.text.substring(0, cursor).contains(':')) {
        _asked = true;
        EmojiData.load().then((_) => _changed(), onError: (Object _) {});
      }
      _show(null, const []);
      return;
    }
    final codes = EmojiShortcodes.of(data);
    final expanded = codes.expand(was, now);
    if (expanded != null) {
      _busy = true;
      try {
        controller.value = expanded;
      } finally {
        _busy = false;
      }
      _was = controller.value;
      _show(null, const []);
      return;
    }
    final q = cursor < 0 ? null : ShortcodeQuery.at(now.text, cursor);
    if (q != _closedOn) _closedOn = null;
    final found = q == null || q == _closedOn ? const <ShortcodeMatch>[] : codes.match(q.text, recent: _recent());
    _show(found.isEmpty ? null : q, found);
  }

  /// Sets what the list shows, telling listeners only where it changed. The chosen row goes back to the first where
  /// the query starts somewhere else or the list grew shorter than it.
  void _show(ShortcodeQuery? q, List<ShortcodeMatch> found) {
    final same = q == _query && found.length == _found.length && [for (var i = 0; i < found.length; i++) found[i].entry == _found[i].entry].every((b) => b);
    if (same) return;
    if (_chosen >= found.length || q?.start != _query?.start) _chosen = 0;
    _query = q;
    _found = found;
    notifyListeners();
  }

  /// [m] in place of the ":jo" being written, the cursor after it.
  void pick(ShortcodeMatch m) {
    final q = _query;
    if (q == null) return;
    final text = controller.text;
    // 0x3A is the colon: where the query no longer starts on one, the words changed under it.
    if (q.end > text.length || text.codeUnitAt(q.start) != 0x3A) return;
    final out = text.replaceRange(q.start, q.end, m.emoji);
    controller.value = TextEditingValue(text: out, selection: TextSelection.collapsed(offset: q.start + m.emoji.length));
    final a = app?.call();
    if (a != null) EmojiChoices(a).used(m.emoji);
    _show(null, const []);
  }

  /// Escape: closes the list, and keeps it closed until the query changes.
  void close() {
    _closedOn = _query;
    _show(null, const []);
  }

  /// A computer's key, taken before the field sees it while the list is open (as [mentionKey] reads it); null where
  /// the key is not the list's.
  KeyEventResult? key(KeyEvent e) {
    if (!open) return null;
    return mentionKey(
      e,
      count: _found.length,
      chosen: _chosen,
      choose: (i) {
        _chosen = i;
        notifyListeners();
      },
      pick: () => pick(_found[_chosen]),
      close: close,
    );
  }

  @override
  void dispose() {
    controller.removeListener(_changed);
    super.dispose();
  }
}

/// The emoji a ":jo" finds, over the composer, drawn as the people an "@…" finds are (MentionSuggestions): each emoji
/// and its ":name:", the chosen one on a wash. Nothing where the list is closed.
class EmojiSuggestions extends StatelessWidget {
  const EmojiSuggestions({super.key, required this.suggester});
  final EmojiShortcodeSuggester suggester;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: suggester,
      builder: (context, _) {
        final found = suggester.found;
        if (found.isEmpty) return const SizedBox.shrink();
        final t = context.tokens;
        final bevel = isBevelChrome(t);
        final radius = bevel ? 0.0 : t.lenOf('1rem');
        return Semantics(
          container: true,
          label: '${found.length} emoji',
          child: Container(
            key: const ValueKey('emoji-suggestions'),
            margin: EdgeInsetsDirectional.fromSTEB(t.space(2), 0, t.space(2), t.space(1)),
            padding: EdgeInsets.symmetric(vertical: t.space(1)),
            decoration: BoxDecoration(
              color: t.color('app-paper'),
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: t.color('app-ink-4'), width: 1),
              boxShadow: bevel ? null : [BoxShadow(color: const Color(0x22000000), blurRadius: t.space(4), offset: Offset(0, t.space(1)))],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (var i = 0; i < found.length; i++) _row(t, found[i], i == suggester.chosen, radius),
            ]),
          ),
        );
      },
    );
  }

  Widget _row(Tokens t, ShortcodeMatch m, bool chosen, double radius) {
    return GlacierPressable(
      key: ValueKey('emoji-suggestion-${m.code}'),
      // The field keeps the keyboard and the cursor: a press here must not take the focus from it.
      canRequestFocus: false,
      onPressed: () => suggester.pick(m),
      semanticLabel: '${m.entry.label}, :${m.code}:',
      builder: (context, state) => Container(
        margin: EdgeInsets.symmetric(horizontal: t.space(1)),
        padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: t.space(1) + 2),
        decoration: BoxDecoration(
          color: chosen || state.hovered || state.pressed ? t.color('app-paper-2') : null,
          borderRadius: BorderRadius.circular(radius == 0 ? 0 : t.lenOf('0.75rem')),
        ),
        child: Row(children: [
          ExcludeSemantics(child: SizedBox(width: 26, child: Text(m.emoji, textAlign: TextAlign.center, style: pageText(t, 20, height: 1.1)))),
          SizedBox(width: t.space(2)),
          Flexible(child: Text(':${m.code}:', maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'medium', color: t.color('app-ink')))),
        ]),
      ),
    );
  }
}
