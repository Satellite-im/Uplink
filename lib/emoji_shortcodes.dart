/// Emoji by shortcode in the composer (GMFB-22, Matt, Mac 0.12.6: "typing :joy: or something should expand the emoji
/// to the joy emoji and auto suggest with a popup").
///
/// - [ShortcodeQuery.at]: the ":jo" being written where the cursor is.
/// - [EmojiShortcodes.match]: the emoji it finds, best first.
/// - [EmojiShortcodes.expand]: a whole ":joy:" put in as 😂 as its closing colon is typed.
///
/// The names are the shortcodes in assets/emoji/emoji.tsv (emojibase-data, MIT; lib/emoji_data.dart reads it), the
/// Slack and GitHub names among them: joy, heart, thumbsup and +1, fire, sob, tada, 100, ok_hand and the rest. Nothing
/// here draws anything: lib/ui/emoji_suggestions.dart puts it on the composer.
library;

import 'package:flutter/services.dart' show TextEditingValue, TextSelection, TextRange;

import 'emoji_data.dart';

/// A ":name" being written: where its colon is in the words and the letters after it, up to the cursor.
class ShortcodeQuery {
  const ShortcodeQuery(this.start, this.text);
  final int start;
  final String text;

  /// Just past the letters: where the cursor is.
  int get end => start + 1 + text.length;

  /// The fewest letters after the colon before anything is offered: one is too many emoji, and ":D" or ":P" is a face
  /// written as it always was.
  static const fewest = 2;

  static final _name = RegExp(r'^[A-Za-z0-9_+\-]+$');
  static final _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);

  /// The ":…" just before [cursor] in [text], or null: a colon at the start of the words or after something that is
  /// not a letter or a digit (so the colons in "10:30:45" and "https://" are left alone), then at least [fewest] of
  /// letters, digits, "_", "+" and "-".
  static ShortcodeQuery? at(String text, int cursor) {
    if (cursor < 0 || cursor > text.length) return null;
    var i = cursor;
    while (i > 0 && _name.hasMatch(text[i - 1])) {
      i--;
    }
    if (i == 0 || text.codeUnitAt(i - 1) != 0x3A) return null;
    final colon = i - 1;
    final name = text.substring(i, cursor);
    if (name.length < fewest) return null;
    if (colon > 0 && _wordChar.hasMatch(text[colon - 1])) return null;
    return ShortcodeQuery(colon, name);
  }

  @override
  bool operator ==(Object other) => other is ShortcodeQuery && other.start == start && other.text == text;

  @override
  int get hashCode => Object.hash(start, text);
}

/// One emoji offered for a query, with the shortcode of its that matched (shown beside it as ":name:").
class ShortcodeMatch {
  const ShortcodeMatch(this.entry, this.code);
  final EmojiEntry entry;
  final String code;
  String get emoji => entry.emoji;
}

/// The emoji's shortcodes, looked up both ways.
class EmojiShortcodes {
  EmojiShortcodes._(this.data, this._byCode);

  final EmojiData data;
  final Map<String, EmojiEntry> _byCode;

  static final _made = Expando<EmojiShortcodes>();

  /// For [data], made once.
  factory EmojiShortcodes.of(EmojiData data) {
    final had = _made[data];
    if (had != null) return had;
    final by = <String, EmojiEntry>{};
    // Where two emoji share a name ("cat": the face and the whole cat) the first in the list has it.
    for (final e in data.all) {
      for (final c in e.codes) {
        by.putIfAbsent(c.toLowerCase(), () => e);
      }
    }
    return _made[data] = EmojiShortcodes._(data, by);
  }

  /// The emoji [code] names, or null where it names none.
  String? emojiFor(String code) => _byCode[code.toLowerCase()]?.emoji;

  /// The most offered at once.
  static const most = 6;

  /// The emoji [query] finds, best first: the shortcode that is the query, then the ones that start with it, then the
  /// ones that have it inside; within each, the ones in [recent] (newest first) ahead, then the shorter name, then the
  /// list's own order. One row for each emoji, with its best name.
  List<ShortcodeMatch> match(String query, {List<String> recent = const [], int limit = most}) {
    final q = query.toLowerCase();
    if (q.isEmpty) return const [];
    final best = <EmojiEntry, (int, String)>{};
    final order = <EmojiEntry, int>{};
    for (final (i, e) in data.all.indexed) {
      for (final raw in e.codes) {
        final c = raw.toLowerCase();
        final tier = c == q ? 0 : c.startsWith(q) ? 1 : c.contains(q) ? 2 : -1;
        if (tier < 0) continue;
        final had = best[e];
        if (had == null || tier < had.$1 || (tier == had.$1 && c.length < had.$2.length)) best[e] = (tier, c);
        order[e] ??= i;
      }
    }
    int used(EmojiEntry e) {
      final at = recent.indexOf(e.emoji);
      return at < 0 ? recent.length : at;
    }

    final found = best.keys.toList()
      ..sort((a, b) {
        final (ta, ca) = best[a]!;
        final (tb, cb) = best[b]!;
        if (ta != tb) return ta.compareTo(tb);
        final ua = used(a), ub = used(b);
        if (ua != ub) return ua.compareTo(ub);
        if (ca.length != cb.length) return ca.length.compareTo(cb.length);
        return order[a]!.compareTo(order[b]!);
      });
    return [for (final e in found.take(limit)) ShortcodeMatch(e, best[e]!.$2)];
  }

  /// [now] with a whole ":name:" put in as its emoji, where the change from [was] has just typed the closing colon at
  /// the cursor and the name is one this list knows; null otherwise. The cursor is left after the emoji. "hi :joy:"
  /// becomes "hi 😂"; "10:30:" and ":nope:" stay as they are. Words put in whole (a draft, a message being edited, a
  /// paste) keep their ":name:"s as written.
  TextEditingValue? expand(TextEditingValue was, TextEditingValue now) {
    final s = now.selection;
    if (!s.isValid || !s.isCollapsed || now.text.length <= was.text.length || now.text.length - was.text.length > 2) return null;
    final text = now.text, cursor = s.baseOffset;
    if (cursor < 1 || cursor > text.length || text.codeUnitAt(cursor - 1) != 0x3A) return null;
    // The closing colon is new: it lies in what changed, not in the words that were there before.
    var head = 0;
    final most = was.text.length < text.length ? was.text.length : text.length;
    while (head < most && was.text.codeUnitAt(head) == text.codeUnitAt(head)) {
      head++;
    }
    if (head > cursor - 1) return null;
    final q = ShortcodeQuery.at(text, cursor - 1);
    if (q == null) return null;
    // The opening colon and the name were there already: only the end of it was typed.
    if (head <= q.start) return null;
    final emoji = emojiFor(q.text);
    if (emoji == null) return null;
    final out = text.replaceRange(q.start, cursor, emoji);
    return TextEditingValue(text: out, selection: TextSelection.collapsed(offset: q.start + emoji.length), composing: TextRange.empty);
  }
}
