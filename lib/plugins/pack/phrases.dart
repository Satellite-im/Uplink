/// The phrase language a pack matches texts with (A.10): literal words, separators and a few vetted tokens such as
/// `{digits:4-8}`, compiled by the app into regular expressions whose every quantifier is its own and bounded. A
/// stranger's pattern never reaches Dart's RegExp, whose backtracking one nested quantifier once ran for 17.8 seconds
/// on a 29-character text.
library;

import 'format.dart';

/// The tokens a phrase may hold.
const Set<String> phraseTokenNames = {'digits', 'number', 'amount', 'code', 'word', 'words', 'url', 'email', 'phone', 'date', 'time'};

/// [text] with the look-alikes texts are typed with made plain, one for one, so its length doesn't change: the
/// spaces that don't break as a space, curly apostrophes and quotes as straight ones, the dashes as a hyphen. Both a
/// text and a phrase's words go through it, so "don't forget" matches "Don’t forget".
String normalizeForPhrases(String text) {
  final units = text.codeUnits;
  List<int>? out;
  for (var i = 0; i < units.length; i++) {
    final plain = _plainUnit(units[i]);
    if (plain == units[i]) continue;
    (out ??= List.of(units))[i] = plain;
  }
  return out == null ? text : String.fromCharCodes(out);
}

// One UTF-16 unit made plain: no-break and narrow spaces to a space, curly quotes to straight ones, the hyphens and
// dashes U+2010 to U+2014 to "-".
int _plainUnit(int unit) => switch (unit) {
      0x00A0 || 0x2007 || 0x202F => 0x20,
      0x2018 || 0x2019 || 0x201B || 0x02BC => 0x27,
      0x201C || 0x201D || 0x201F => 0x22,
      >= 0x2010 && <= 0x2014 => 0x2D,
      _ => unit,
    };

/// A text as phrases are matched against it: made plain ([normalizeForPhrases]) and cut to its first
/// [PackLimits.scan] code units, which bounds what any phrase can cost, and lower-cased for the anchors' quick look.
class PreparedText {
  PreparedText(String raw) : this._(_cut(normalizeForPhrases(raw)));

  PreparedText._(this.text) : lower = text.toLowerCase();

  final String text;

  /// [text] lower-cased, for anchors.
  final String lower;

  // Cut to the scan, and never ending on half of a character: a high surrogate whose low half was cut off goes too.
  static String _cut(String s) {
    final cut = s.length > PackLimits.scan ? s.substring(0, PackLimits.scan) : s;
    if (cut.isEmpty) return cut;
    final last = cut.codeUnitAt(cut.length - 1);
    return last >= 0xD800 && last <= 0xDBFF ? cut.substring(0, cut.length - 1) : cut;
  }
}

/// Why a phrase isn't one: a phrase_* code (A.14) and plain words for the developer.
class PhraseError implements Exception {
  const PhraseError(this.code, this.message);

  /// A phrase_* code of A.14.
  final String code;
  final String message;

  @override
  String toString() => 'PhraseError($code): $message';
}

/// Where a phrase matched a text: the whole match, and the first token's capture.
class PhraseHit {
  const PhraseHit(this.match, this.token);

  /// The whole match, trimmed.
  final String match;

  /// The first token's capture, trimmed; null where the phrase has no token.
  final String? token;
}

// --- the tokens' fragments (A.10.3) ---------------------------------------------------------------------------------------
//
// Each token is self-delimiting: its lookarounds fix its length to the run it sits on, so at any start it can match in
// a few ways at most. {number} and {phone} are the two whose own separators (a number's . and , and a phone's spaces,
// brackets, dots and dashes) are also what joins one token to the next in a phrase, so as A.10.3 first wrote them each
// could stop after any group of a run and start again after any separator; a phrase chaining four phones then tried
// some 9^4 ways at every start, 0.8 s a search on a stranger's "1 1 1 …" (review, 2026-11-20). Both are maximal now: a
// number never starts just after "1." or "1," nor stops before ".1" or ",1", and a phone never starts or stops beside
// another of its own separators and a digit, so each takes the whole run or nothing.

const String _num = r'(?<![0-9]|[0-9][.,])(?:[0-9]{1,3}(?:[.,][0-9]{3}){1,4}|[0-9]{1,15})(?:[.,][0-9]{1,2})?(?![0-9]|[.,][0-9])';
const String _cur = r'(?:[$€£¥₹]|(?<![\p{L}\p{N}])(?:usd|eur|gbp|cad|aud)(?![\p{L}]))';
// Longer names first: an alternation takes the first that fits, and "sept" must not stop at "sep".
const String _month = r'(?:january|february|march|april|may|june|july|august|september|october|november|december|sept|jan|feb|mar|apr|jun|jul|aug|sep|oct|nov|dec)';

// The RegExp source of the token [name]; [n] and [m] are its arguments, for the tokens that take them ({digits} and
// {code}). {words} has no fragment here: [Phrase._pattern] writes it, with its separators.
String _fragment(String name, int n, int m) => switch (name) {
      'digits' => '(?<![0-9])[0-9]{$n,$m}(?![0-9])',
      'number' => _num,
      'amount' => '(?:$_cur${r'\s?'}$_num|$_num${r'\s?'}$_cur)',
      'code' => '${r'(?<![\p{L}\p{N}])(?=[A-Za-z]{0,23}[0-9])[A-Za-z0-9]'}{$n,$m}${r'(?![\p{L}\p{N}])'}',
      'word' => r"(?<![\p{L}\p{N}'-])[\p{L}\p{N}][\p{L}\p{N}'-]{0,31}(?![\p{L}\p{N}'-])",
      'url' => r'(?:https?://|www\.)[^\s<>"]{1,200}',
      'email' => r'(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9-]{1,63}(?:\.[A-Za-z0-9-]{1,63}){1,4}(?![A-Za-z0-9-])',
      'phone' => r'(?<![0-9+]|[0-9][ ().-]{1,2})\+?[0-9](?:[ ().-]{0,2}[0-9]){6,14}(?![0-9]|[ ().-]{1,2}[0-9])',
      'date' => '(?:${r'(?<![0-9])[0-9]{1,4}[/.-][0-9]{1,2}(?:[/.-][0-9]{2,4})?(?![0-9])'}|${r'(?<![\p{L}])'}$_month${r'\.?\s[0-9]{1,2}(?:st|nd|rd|th)?(?![\p{L}\p{N}])'}|${r'(?<![0-9])[0-9]{1,2}(?:st|nd|rd|th)?\s'}$_month${r'(?![\p{L}]))'}',
      'time' => r'(?<![0-9:])(?:[0-9]{1,2}(?::[0-5][0-9])?\s?(?:a\.m\.|p\.m\.|am|pm)(?![\p{L}])|[0-9]{1,2}:[0-5][0-9](?![0-9]))',
      _ => throw StateError('No token $name'),
    };

// What a token's arguments may be (A.10.3): its lowest and highest N and M, and what it is with none given. A token
// not here takes no arguments.
const Map<String, (int, int, int, int)> _ranges = {'digits': (1, 24, 1, 24), 'code': (4, 24, 4, 10), 'words': (0, 4, 1, 3)};

final RegExp _tokenInside = RegExp(r'^([a-z]+)(?::([0-9]{1,2})(?:-([0-9]{1,2}))?)?$');
final RegExp _space = RegExp(r'\s');
final RegExp _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);
final RegExp _wordRun = RegExp(r'[\p{L}\p{N}]+', unicode: true);
final RegExp _asciiRun = RegExp(r'^[A-Za-z0-9]{3,}$');
const String _special = r'\^$.*+?()[]{}|';

/// What a phrase is read into: literal words, a separator (any run of spaces in the source), or a token.
sealed class _Piece {
  const _Piece();
}

final class _Literal extends _Piece {
  const _Literal(this.text);
  final String text;
}

final class _Separator extends _Piece {
  const _Separator();
}

/// A token by its name, with its two numbers ([_ranges]); both 0 for one that takes none.
final class _Token extends _Piece {
  const _Token(this.name, this.n, this.m);
  final String name;
  final int n, m;
}

bool _isWordChar(String char) => _wordChar.hasMatch(char);

// The first and last characters of a literal, whole (a letter beyond the BMP is two code units).
String _firstChar(String s) => String.fromCharCode(s.runes.first);
String _lastChar(String s) => String.fromCharCode(s.runes.last);

/// One compiled phrase. [Phrase.compile] checks it (A.10.2 to A.10.4) and writes its RegExp (A.10.5); [find] runs it
/// only where the text holds its anchor (A.10.6).
class Phrase {
  /// A.10.2 to A.10.5; throws PhraseError.
  factory Phrase.compile(String source) {
    if (source.isEmpty || source.length > PackLimits.phrase || !packTextOk(source)) {
      throw PhraseError('phrase_bad_text', source.isEmpty ? 'A phrase can\'t be empty.' : source.length > PackLimits.phrase ? 'A phrase is at most ${PackLimits.phrase} characters: this one is ${source.length}.' : '"$source" holds a character a phrase can\'t (a line break, an invisible one, or a space at either end).');
    }
    final pieces = _read(normalizeForPhrases(source));
    _checkShape(pieces, source);
    final pattern = _pattern(pieces);
    final RegExp regExp;
    try {
      regExp = RegExp(pattern, unicode: true, caseSensitive: false);
    } on FormatException {
      // Every piece of a pattern is the app's own, so this would be a bug here, never a developer's mistake; it is
      // still refused as a phrase rather than thrown at whoever is checking the pack.
      throw PhraseError('phrase_bad_token', '"$source" couldn\'t be made into a pattern.');
    }
    return Phrase._(source, pattern, _anchorOf(pieces), pieces.any((p) => p is _Token), regExp);
  }

  /// The person's own words (A.10.10): braces doubled, then compiled.
  factory Phrase.literal(String words) => Phrase.compile(words.replaceAll('{', '{{').replaceAll('}', '}}'));

  // Made only by compile, from a phrase it has checked, with the pattern it wrote: never from a stranger's RegExp.
  Phrase._(this.source, this.pattern, this.anchor, this.hasToken, this._regExp);

  final String source;

  /// The RegExp source, shown to the reviewer and pinned by tests.
  final String pattern;
  final String? anchor;
  final bool hasToken;
  final RegExp _regExp;

  bool get anchorless => anchor == null;

  /// A.10.6 and A.10.7: null where it doesn't match. The anchor is part of what matching is, not only a quick look:
  /// a phrase whose anchor isn't in the text doesn't match it, whatever its RegExp would say.
  PhraseHit? find(PreparedText text) {
    final anchor = this.anchor;
    if (anchor != null && !text.lower.contains(anchor)) return null;
    final m = _regExp.firstMatch(text.text);
    if (m == null) return null;
    return PhraseHit(m[0]!.trim(), hasToken ? (m[1] ?? '').trim() : null);
  }

  bool matches(PreparedText text) => find(text) != null;

  @override
  String toString() => 'Phrase($source)';

  // --- reading a phrase (A.10.2) ----------------------------------------------------------------------------------------

  /// [s] as pieces: {name} a token, {{ and }} a brace itself, any run of spaces one separator, the rest literal.
  static List<_Piece> _read(String s) {
    final pieces = <_Piece>[];
    final literal = StringBuffer();
    void flush() {
      if (literal.isEmpty) return;
      pieces.add(_Literal(literal.toString()));
      literal.clear();
    }

    var i = 0;
    while (i < s.length) {
      final c = s[i];
      if (c == '{') {
        if (i + 1 < s.length && s[i + 1] == '{') {
          literal.write('{');
          i += 2;
          continue;
        }
        final end = s.indexOf('}', i + 1);
        if (end < 0) throw const PhraseError('phrase_bad_token', 'A "{" is never closed: write {{ for a brace itself.');
        flush();
        pieces.add(_token(s.substring(i + 1, end)));
        i = end + 1;
        continue;
      }
      if (c == '}') {
        if (i + 1 < s.length && s[i + 1] == '}') {
          literal.write('}');
          i += 2;
          continue;
        }
        throw const PhraseError('phrase_bad_token', 'A "}" with no "{" before it: write }} for a brace itself.');
      }
      if (_space.hasMatch(c)) {
        flush();
        if (pieces.isEmpty || pieces.last is! _Separator) pieces.add(const _Separator());
        i++;
        continue;
      }
      literal.write(c);
      i++;
    }
    flush();
    return pieces;
  }

  /// The token written between braces as [inside]: `name`, `name:N` or `name:N-M`, its numbers within [_ranges].
  static _Token _token(String inside) {
    final m = _tokenInside.firstMatch(inside);
    final name = m?.group(1);
    if (m == null || name == null || !phraseTokenNames.contains(name)) {
      throw PhraseError('phrase_bad_token', '"{$inside}" is not a token: they are ${phraseTokenNames.map((t) => '{$t}').join(', ')}.');
    }
    final range = _ranges[name];
    final n = m.group(2), mm = m.group(3);
    if (range == null) {
      if (n != null) throw PhraseError('phrase_bad_token', '{$name} takes no numbers: write it as {$name}.');
      return _Token(name, 0, 0);
    }
    final (lo, hi, dn, dm) = range;
    if (n == null) return _Token(name, dn, dm);
    final low = int.parse(n), high = mm == null ? low : int.parse(mm);
    if (low < lo || high > hi || low > high) throw PhraseError('phrase_bad_token', '"{$inside}": {$name} takes $lo to $hi, the lower number first.');
    return _Token(name, low, high);
  }

  // --- its shape (A.10.4), the first broken rule being the error ----------------------------------------------------

  static void _checkShape(List<_Piece> pieces, String source) {
    for (var i = 0; i < pieces.length; i++) {
      if (pieces[i] is _Token && i + 1 < pieces.length && pieces[i + 1] is _Token) throw PhraseError('phrase_tokens_touch', '"$source": two tokens with nothing between them.');
    }
    for (var i = 0; i < pieces.length; i++) {
      if (pieces[i] is! _Token) continue;
      final before = i > 0 ? pieces[i - 1] : null, after = i + 1 < pieces.length ? pieces[i + 1] : null;
      if ((before is _Literal && _isWordChar(_lastChar(before.text))) || (after is _Literal && _isWordChar(_firstChar(after.text)))) {
        throw PhraseError('phrase_token_touches_word', '"$source": a token touches a letter or a digit: put a space between them.');
      }
    }
    var tokens = 0, words = 0, urls = 0;
    for (var i = 0; i < pieces.length; i++) {
      final p = pieces[i];
      if (p is! _Token) continue;
      if (p.name == 'words' && (i < 2 || i > pieces.length - 3 || pieces[i - 1] is! _Separator || pieces[i + 1] is! _Separator)) {
        throw PhraseError('phrase_words_edge', '"$source": {words} goes between other words, with a space on each side.');
      }
    }
    for (var i = 0; i < pieces.length; i++) {
      final p = pieces[i];
      if (p is _Token && p.name == 'url' && i + 1 < pieces.length && pieces[i + 1] is! _Separator) {
        throw PhraseError('phrase_url_followed', '"$source": {url} can only be followed by a space or the end.');
      }
    }
    for (final p in pieces) {
      if (p is! _Token) continue;
      tokens++;
      if (p.name == 'words') words++;
      if (p.name == 'url') urls++;
    }
    if (tokens > PackLimits.tokens || words > 1 || urls > 1) throw PhraseError('phrase_too_many_tokens', '"$source": at most ${PackLimits.tokens} tokens, one {words} and one {url}.');
    if (tokens == 0) {
      final letters = [for (final p in pieces) if (p is _Literal) p.text].join().runes.where((r) => _isWordChar(String.fromCharCode(r))).length;
      if (letters < 2) throw PhraseError('phrase_too_short', '"$source": a phrase without a token needs two letters or digits at least.');
    }
  }

  // --- its RegExp (A.10.5) ------------------------------------------------------------------------------------------

  /// The pieces as one RegExp source: literals escaped, a separator `\s+`, each token its fragment, the first token
  /// alone captured. An end that is a letter or a digit must not touch another in the text.
  static String _pattern(List<_Piece> pieces) {
    final out = StringBuffer();
    var captured = false;
    void token(String fragment) {
      out.write(captured ? fragment : '($fragment)');
      captured = true;
    }

    for (var i = 0; i < pieces.length; i++) {
      final p = pieces[i];
      switch (p) {
        case _Literal(:final text):
          for (final rune in text.runes) {
            final c = String.fromCharCode(rune);
            out.write(_special.contains(c) ? '\\$c' : c);
          }
        case _Separator():
          // The separator before {words} is the words' own (theirs is the whole run, separators and all).
          if (i + 1 < pieces.length && pieces[i + 1] is _Token && (pieces[i + 1] as _Token).name == 'words') continue;
          out.write(r'\s+');
        case _Token(name: 'words', :final n, :final m):
          out.write(r'\s+');
          token('${r'(?:\S{1,32}\s+)'}{$n,$m}');
          i++; // and the separator after them
        case _Token(:final name, :final n, :final m):
          token(_fragment(name, n, m));
      }
    }
    final first = pieces.first, last = pieces.last;
    final head = first is _Literal && _isWordChar(_firstChar(first.text)) ? r'(?<![\p{L}\p{N}])' : '';
    final tail = last is _Literal && _isWordChar(_lastChar(last.text)) ? r'(?![\p{L}\p{N}])' : '';
    return '$head$out$tail';
  }

  // --- its anchor (A.10.6) ------------------------------------------------------------------------------------------

  /// The longest run of three or more ASCII letters and digits among its literal words, lower-cased; null where it
  /// has none.
  static String? _anchorOf(List<_Piece> pieces) {
    String? anchor;
    for (final p in pieces) {
      if (p is! _Literal) continue;
      for (final run in _wordRun.allMatches(p.text)) {
        final word = run[0]!;
        if (_asciiRun.hasMatch(word) && (anchor == null || word.length > anchor.length)) anchor = word;
      }
    }
    return anchor?.toLowerCase();
  }
}
