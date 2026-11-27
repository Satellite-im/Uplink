/// Formatting written into a message's words (GMFB-35, from the Uplink gap review: "Markdown formatting in
/// messages"): **bold** (or __bold__), *italic* (or _italic_), ~~strike~~, `code`, ```a block of code```, "> " a quote at a line's
/// start, ||a spoiler|| hidden until pressed, [words](https://…) for a link under other words, and lists: a line that
/// starts "- ", "* " or "1. " is an item, its mark drawn as a bullet or its number with the lines hanging beside it.
///
/// The markers stay in the words as they were written and go out so: a build from before this, a text, Telegram and
/// the rest show the asterisks, and this app draws them. [MessageFormat.parse] says, for each stretch of the words, how
/// it is drawn and which markers are not drawn at all; [MessageFormat.plain] is the words without them (a
/// notification's preview, a spoiler as ▒).
///
/// The rules keep everyday words as they are: a marker opens only before a letter, not a space, and closes only after
/// one, all on one line; a single * or _ opens only where no letter or digit stands just before it and closes only
/// where none follows ("2*3*4" and snake_case stay as written). Nothing inside code is formatted. Links and mentions
/// ([MessageFormat.parse]'s `keep`) are whole: no marker is read inside one, and they keep working inside formatting.
/// A backslash before a marker writes the marker itself.
///
/// Nothing here draws anything: LinkedText (lib/ui/thread.dart) draws the words with it, and MarkdownController
/// (lib/ui/markdown_field.dart) dims the markers in the composer.
library;

import 'links.dart';

/// How a stretch of the words is drawn: a mix of these.
abstract final class Fmt {
  static const bold = 1;
  static const italic = 2;
  static const strike = 4;
  static const code = 8;
  static const block = 16;
  static const quote = 32;
  static const spoiler = 64;
  static const link = 128;
}

/// One stretch of the words, [start] to [end] (UTF-16 code units, as a Dart string counts), and how it is drawn.
class FormatRun {
  const FormatRun(this.start, this.end, this.flags, {this.marker = false, this.bar = false, this.item = false, this.spoiler = -1, this.link = -1});

  final int start, end;

  /// [Fmt]s.
  final int flags;

  /// A marker: not drawn.
  final bool marker;

  /// A quote's "> ": drawn as a bar at the line's start in place of its own characters.
  final bool bar;

  /// A list item's mark, the spaces before it and the one after ("- ", "  * ", "12. "): drawn as a bullet or the
  /// number at the line's start, the rest of the line hanging beside it ([MessageFormat.itemMark]). The line is the
  /// item: it ends at the line's end.
  final bool item;

  /// Which spoiler it is in (counted from 0 in the order they come), or -1.
  final int spoiler;

  /// For the words of a [words](address) link: which of the links given to [MessageFormat.parse] it opens, or -1.
  final int link;

  /// Whether it is drawn with [f] (one [Fmt], or any of several).
  bool has(int f) => flags & f != 0;

  @override
  String toString() => 'FormatRun($start-$end ${marker ? 'marker' : bar ? 'bar' : item ? 'item' : flags}${spoiler >= 0 ? ' s$spoiler' : ''}${link >= 0 ? ' l$link' : ''})';
}

/// A message's words read for formatting.
class MessageFormat {
  const MessageFormat._(this.text, this.runs, this.spoilers);

  final String text;

  /// The whole of [text], in order, each run beginning where the one before it ends.
  final List<FormatRun> runs;

  /// How many spoilers there are.
  final int spoilers;

  /// Nothing in it is formatted: drawn as it was written.
  bool get isPlain => runs.every((r) => r.flags == 0 && !r.marker && !r.bar && !r.item);

  /// Whether it has a list in it.
  bool get hasItems => runs.any((r) => r.item);

  /// A list item's mark as it is drawn, and how far in it stands (0 at the edge, up to 3), from the item run's own
  /// characters [mark] ("  - ", "3. "): "•" for a "-" or a "*", a number as it was written.
  static (String, int) itemMark(String mark) {
    final m = mark.trim();
    final depth = ((mark.length - mark.trimLeft().length) ~/ 2).clamp(0, 3);
    return (m == '-' || m == '*' ? '\u2022' : m, depth);
  }

  /// A list item's mark at the start of a line: up to six spaces, then "-" or "*", or a number of up to three digits
  /// and a "." or ")", then one space and something after it. A year and a full stop ("2020. What a year") is not one.
  static final _item = RegExp(r' {0,6}(?:[-*]|\d{1,3}[.)]) (?=\S)');

  /// Longer words than this are drawn as written: nobody formats a book, and reading one is not free.
  static const longest = 20000;

  /// The characters a backslash can make plain.
  static const _escapable = r'*_~`|[]>\';

  /// [text] read for formatting. [keep]: stretches read as they are, no marker inside them (the mentions); [links]:
  /// the links in it ([MessageLink.find]), kept whole too, and what a [words](address) opens is one of them.
  static MessageFormat parse(String text, {List<(int, int)> keep = const [], List<(int, int)> links = const []}) {
    final n = text.length;
    if (n == 0) return MessageFormat._(text, const [], 0);
    if (n > longest || !_mayHave(text)) return MessageFormat._(text, [FormatRun(0, n, 0)], 0);
    return _Reader(text, keep, links).read();
  }

  /// Whether [text] has any character that could start formatting, or a line that could start a list (a "-" or a
  /// digit first on it): most messages have none, and are not read.
  static bool _mayHave(String text) {
    var first = true;
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      switch (c) {
        case 0x2A || 0x5F || 0x7E || 0x60 || 0x7C || 0x5B || 0x3E || 0x5C:
          return true;
      }
      if (first && (c == 0x2D || (c >= 0x30 && c <= 0x39))) return true;
      if (c == 0x0A) {
        first = true;
      } else if (c != 0x20) {
        first = false;
      }
    }
    return false;
  }

  /// [text] without its markers, as a notification's preview says it: a quote's "> " gone, a spoiler as ▒s, a
  /// [words](address) as its words.
  static String plain(String text) {
    final found = MessageLink.find(text);
    final f = parse(text, links: [for (final l in found) (l.start, l.end)]);
    if (f.isPlain) return text;
    final out = StringBuffer();
    var lastSpoiler = -1;
    var shown = 0;
    for (final r in f.runs) {
      if (r.marker || r.bar) continue;
      if (r.spoiler >= 0) {
        if (r.spoiler != lastSpoiler) shown = 0;
        lastSpoiler = r.spoiler;
        // As many ▒ as letters, up to a few: how long it is, not what it says.
        final room = 8 - shown;
        final add = (r.end - r.start).clamp(0, room);
        out.write('▒' * add);
        shown += add;
        continue;
      }
      out.write(text.substring(r.start, r.end));
    }
    return out.toString();
  }
}

/// One reading of a message's words: for each code unit how it is drawn, filled in a pass for blocks of code and
/// then a pass for each line, and gathered into runs at the end ([read]).
class _Reader {
  _Reader(this.text, List<(int, int)> keep, this.links)
      : n = text.length,
        flags = List.filled(text.length, 0),
        marker = List.filled(text.length, false),
        bar = List.filled(text.length, false),
        item = List.filled(text.length, false),
        spoiler = List.filled(text.length, -1),
        link = List.filled(text.length, -1),
        locked = List.filled(text.length, false),
        whole = List.filled(text.length + 1, -1) {
    for (final (s, e) in [...keep, ...links]) {
      final a = s.clamp(0, n), b = e.clamp(0, n);
      // [whole][i]: where the kept stretch that starts at or covers i ends.
      for (var i = a; i < b; i++) {
        if (whole[i] < b) whole[i] = b;
      }
    }
  }

  // For each code unit of [text] (n of them): its [Fmt]s; whether it is a marker, a quote's bar, or locked (code, or a
  // marker: nothing more is read in it), or a list item's mark; which spoiler and which link it is in (-1 none); and [whole], set above.
  final String text;
  final int n;
  final List<(int, int)> links;
  final List<int> flags;
  final List<bool> marker, bar, item, locked;
  final List<int> spoiler, link;
  final List<int> whole;
  var _spoilers = 0;

  /// Whether [i] is inside a link or a mention kept whole.
  bool _kept(int i) => i < n && whole[i] >= 0;

  /// Reads the blocks of code, then each line, and gathers the code units drawn alike into runs.
  MessageFormat read() {
    _blocks();
    var ls = 0;
    while (ls <= n) {
      var le = text.indexOf('\n', ls);
      if (le < 0) le = n;
      _line(ls, le);
      ls = le + 1;
    }
    final runs = <FormatRun>[];
    var start = 0;
    for (var i = 1; i <= n; i++) {
      if (i == n || flags[i] != flags[start] || marker[i] != marker[start] || bar[i] != bar[start] || item[i] != item[start] || spoiler[i] != spoiler[start] || link[i] != link[start]) {
        runs.add(FormatRun(start, i, flags[start], marker: marker[start], bar: bar[start], item: item[start], spoiler: spoiler[start], link: link[start]));
        start = i;
      }
    }
    return MessageFormat._(text, runs, _spoilers);
  }

  /// [a] to [b] is a marker: not drawn, and nothing more is read in it.
  void _hide(int a, int b) {
    for (var i = a; i < b; i++) {
      marker[i] = true;
      locked[i] = true;
    }
  }

  /// ```blocks of code```: found first, since nothing in one is anything but code.
  void _blocks() {
    var from = 0;
    while (true) {
      final open = _fence(from);
      if (open < 0) return;
      final close = _fence(open + 3);
      if (close < 0) return;
      var a = open + 3, b = close;
      // A language named after the opening fence ("```dart") and the line break after it are not drawn; nor the
      // line break before the closing one.
      final lang = RegExp(r'[A-Za-z0-9+#.\-]*\n').matchAsPrefix(text, a);
      if (lang != null) a = lang.end;
      if (b > a && text.codeUnitAt(b - 1) == 0x0A) b--;
      if (b <= a || text.substring(a, b).trim().isEmpty) {
        from = close;
        continue;
      }
      _hide(open, a);
      _hide(b, close + 3);
      for (var i = a; i < b; i++) {
        flags[i] |= Fmt.code | Fmt.block;
        locked[i] = true;
      }
      from = close + 3;
    }
  }

  /// Where the next ``` at or after [from] is that is not inside something kept whole nor after a backslash; -1 none.
  int _fence(int from) {
    var at = from;
    while (true) {
      final i = text.indexOf('```', at);
      if (i < 0) return -1;
      if (!_kept(i) && !(i > 0 && text.codeUnitAt(i - 1) == 0x5C)) return i;
      at = i + 1;
    }
  }

  /// One line, [ls] to [le]: a quote where it starts with "> " or a list item where it starts with its mark, then the
  /// inline markers in each stretch of it that is not locked.
  void _line(int ls, int le) {
    var base = 0;
    var a = ls;
    // "> " at the start of a line (not inside a block of code) quotes it.
    if (le - ls >= 3 && !locked[ls] && !_kept(ls) && text.startsWith('> ', ls) && text.substring(ls + 2, le).trim().isNotEmpty) {
      bar[ls] = bar[ls + 1] = true;
      locked[ls] = locked[ls + 1] = true;
      base = Fmt.quote;
      a = ls + 2;
      for (var i = a; i < le; i++) {
        flags[i] |= Fmt.quote;
      }
    }
    // "- ", "* " or "1. " at the start of a line (not inside a block of code, nor a quote) makes it a list item. Nothing
    // of the mark is inside a mention or a link, and the line has no block of code's fence on it: an item is one line.
    final mark = base == 0 ? MessageFormat._item.matchAsPrefix(text, ls) : null;
    if (mark != null && mark.end < le && ![for (var i = ls; i < le; i++) locked[i] || (i < mark.end && _kept(i))].contains(true)) {
      for (var i = ls; i < mark.end; i++) {
        item[i] = true;
        locked[i] = true;
      }
      a = mark.end;
    }
    // Each stretch of the line outside a block of code on its own.
    var s = a;
    while (s < le) {
      while (s < le && locked[s]) {
        s++;
      }
      var e = s;
      while (e < le && !locked[e]) {
        e++;
      }
      if (e > s) _inline(s, e, base, -1, -1);
      s = e;
    }
  }

  /// The code unit at [i] is drawn with [base], in spoiler [sp] and link [lk] where those are not -1.
  void _apply(int i, int base, int sp, int lk) {
    flags[i] |= base;
    if (sp >= 0) spoiler[i] = sp;
    if (lk >= 0) {
      link[i] = lk;
      flags[i] |= Fmt.link;
    }
  }

  /// Whether [c] is a space, a tab, a line break or a no-break space.
  static bool _space(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0xA0;

  /// A letter or a digit, of any script.
  static final _word = RegExp(r'[\p{L}\p{N}]', unicode: true);
  /// Whether a letter or a digit, of any script, stands at [i].
  bool _wordAt(int i) => i >= 0 && i < n && _word.hasMatch(text[i]);

  /// The inline markers in [a] to [b], which is already drawn with [base], in spoiler [sp] and link [lk]: what a pair
  /// of markers holds is read the same way, with the pair's own format added.
  void _inline(int a, int b, int base, int sp, int lk) {
    var i = a;
    while (i < b) {
      if (_kept(i)) {
        final end = whole[i].clamp(i + 1, b);
        for (var k = i; k < end; k++) {
          _apply(k, base, sp, lk);
        }
        i = end;
        continue;
      }
      final c = text.codeUnitAt(i);
      // \* is an asterisk.
      if (c == 0x5C && i + 1 < b && !_kept(i + 1) && MessageFormat._escapable.contains(text[i + 1])) {
        marker[i] = true;
        _apply(i + 1, base, sp, lk);
        i += 2;
        continue;
      }
      if (c == 0x60) {
        final j = _codeEnd(i, b);
        if (j > 0) {
          marker[i] = marker[j] = true;
          for (var k = i + 1; k < j; k++) {
            _apply(k, base | Fmt.code, sp, lk);
          }
          i = j + 1;
          continue;
        }
      }
      if (c == 0x5B && lk < 0) {
        final j = _masked(i, b, base, sp);
        if (j > 0) {
          i = j;
          continue;
        }
      }
      final j = _pair(i, b, base, sp, lk);
      if (j > 0) {
        i = j;
        continue;
      }
      _apply(i, base, sp, lk);
      i++;
    }
  }

  /// The closing ` of a `code` opened at [i], or -1.
  int _codeEnd(int i, int b) {
    final j = text.indexOf('`', i + 1);
    if (j < 0 || j >= b || j == i + 1) return -1;
    return j;
  }

  static const _pairs = [('||', Fmt.spoiler), ('~~', Fmt.strike), ('**', Fmt.bold), ('__', Fmt.bold), ('*', Fmt.italic), ('_', Fmt.italic)];

  /// A **pair** of markers opened at [i]: read, and where the words after its closing one begin; -1 where none.
  int _pair(int i, int b, int base, int sp, int lk) {
    for (final (m, f) in _pairs) {
      final len = m.length;
      if (!text.startsWith(m, i)) continue;
      final single = len == 1;
      final at = i + len;
      if (at >= b || _space(text.codeUnitAt(at))) continue;
      // "**" read as two of "*" only where it is not a "**" of its own.
      if (single && text.startsWith(m, at)) continue;
      // "__" is bold as Markdown has it, and like a single one keeps to the edges of words: a__b__c stays as written.
      final edged = single || m == '__';
      if (edged && _wordAt(i - 1)) continue;
      final j = _closer(m, at + 1, b, single, edged);
      if (j < 0) continue;
      for (var k = i; k < at; k++) {
        marker[k] = true;
      }
      for (var k = j; k < j + len; k++) {
        marker[k] = true;
      }
      var s = sp;
      if (f == Fmt.spoiler) s = _spoilers++;
      _inline(at, j, base | f, s, lk);
      return j + len;
    }
    return -1;
  }

  /// Where [m] closes, searching from [from] up to [b]: after a letter, not a space; for a single one and for "__"
  /// ([edged]), before no letter or digit. Code and kept stretches are passed over whole.
  int _closer(String m, int from, int b, bool single, bool edged) {
    final len = m.length;
    var j = from;
    while (j + len <= b) {
      if (_kept(j)) {
        j = whole[j];
        continue;
      }
      final c = text.codeUnitAt(j);
      if (c == 0x5C && j + 1 < b) {
        j += 2;
        continue;
      }
      if (c == 0x60) {
        final e = _codeEnd(j, b);
        if (e > 0) {
          j = e + 1;
          continue;
        }
      }
      if (text.startsWith(m, j) && !_space(text.codeUnitAt(j - 1)) && !_kept(j + len - 1)) {
        // "***x***": the last of a run of them closes.
        var k = j;
        while (k + len < b && text.codeUnitAt(k + len) == m.codeUnitAt(0) && !_kept(k + len)) {
          k++;
        }
        if (single && k != j) {
          // "*a**" is not an italic a.
          j = k + len;
          continue;
        }
        if (edged && _wordAt(k + len)) {
          j = k + len;
          continue;
        }
        return k;
      }
      j++;
    }
    return -1;
  }

  /// A [words](address) opened at [i], where address is one of the links: read, and where the words after it begin;
  /// -1 where it is not one. Words that are an address themselves stay as written, so what a link says is never
  /// another place than where it goes.
  int _masked(int i, int b, int base, int sp) {
    final close = text.indexOf('](', i + 1);
    if (close < 0 || close + 2 >= b) return -1;
    final label = text.substring(i + 1, close);
    if (label.trim().isEmpty || label.contains('[') || label.contains(']')) return -1;
    for (var k = i + 1; k < close; k++) {
      if (_kept(k)) return -1;
    }
    final at = close + 2;
    for (var x = 0; x < links.length; x++) {
      final (s, e) = links[x];
      if (s != at || e >= b || text.codeUnitAt(e) != 0x29) continue;
      if (MessageLink.find(label).isNotEmpty || MessageLink.openable(label.trim()) != null || RegExp(r'\S\.[A-Za-z]{2,}').hasMatch(label)) return -1;
      marker[i] = true;
      _inline(i + 1, close, base, sp, x);
      _hide(close, e + 1);
      return e + 1;
    }
    return -1;
  }
}
