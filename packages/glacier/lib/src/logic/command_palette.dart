/// Command palette logic: the matching, grouping and cursor rules behind a ⌘K overlay.
///
/// A port of `@glacier/logic` (packages/logic/src/command-palette.ts), function for function and line for line where
/// the language allows, so the Flutter palette answers a query with the same list in the same order as the web one.
/// Plain Dart: nothing here knows about widgets.
///
/// What differs from the TypeScript:
/// - `undefined` is `null`.
/// - `isCommandShortcut` takes its three fields as named arguments rather than an event object.
/// - [highlightSegments] slices as JavaScript's `slice` does, clamping to the string, because Dart's `substring`
///   throws where a lower-cased haystack is longer than its label (a dotted capital I) and JavaScript shrugs.
/// - [CommandDescriptor.band] and [CommandDescriptor.detail] are this port's own, for an app that offers more than
///   its commands in one list (Ghost.md's Settings and plugins after its notes and commands; Matt, 2026-10-29: "Add
///   the ability to search settings and plugins from the command search"). Left at their defaults, every row is in
///   band 0 with no detail, and the list is the TypeScript's.
library;

import 'dart:math' as math;

/// A single runnable command.
class CommandDescriptor {
  const CommandDescriptor({required this.id, required this.label, this.group, this.keywords, this.shortcut, this.disabled = false, this.band = 0, this.detail});

  /// Stable identity; also what `onRun` reports back.
  final String id;

  /// The line the user reads.
  final String label;

  /// Optional heading this command files under, e.g. "Navigation".
  final String? group;

  /// Extra words the query should match but the list should not show: aliases, old names, the thing a user would
  /// guess before learning the real label.
  final String? keywords;

  /// Key hint rendered on the trailing edge, e.g. "⌘S". Display only.
  final String? shortcut;

  /// Listed but not runnable; the cursor skips it.
  final bool disabled;

  /// Which run of the list it is offered in: every match of a lower band comes before any of a higher one, however
  /// well the query hit each, and the tiers order them within their band ([matchCommands]). For a list that offers
  /// what is not a command after its commands, so a good hit on a setting's name cannot push a command down.
  final int band;

  /// Words drawn small at the row's trailing edge, before its shortcut: where the thing is ("Appearance") or how it
  /// stands ("Added"). Display only: the query never matches it.
  final String? detail;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CommandDescriptor &&
          other.runtimeType == runtimeType &&
          other.id == id &&
          other.label == label &&
          other.group == group &&
          other.keywords == keywords &&
          other.shortcut == shortcut &&
          other.disabled == disabled &&
          other.band == band &&
          other.detail == detail;

  @override
  int get hashCode => Object.hash(runtimeType, id, label, group, keywords, shortcut, disabled, band, detail);

  @override
  String toString() => 'CommandDescriptor($id, "$label"${group == null ? '' : ', group: $group'}${disabled ? ', disabled' : ''})';
}

/// A command that survived the query, plus why.
///
/// [matchedKeyword] is set only when the query hit a keyword and not the label, so the list can show the user the
/// word they actually typed rather than a row that looks unrelated to their query.
class CommandMatch<T extends CommandDescriptor> {
  const CommandMatch({required this.item, this.matchedKeyword, required this.index});

  final T item;
  final String? matchedKeyword;

  /// Position in the flat result order: the index the cursor addresses.
  final int index;

  @override
  bool operator ==(Object other) => other is CommandMatch && other.item == item && other.matchedKeyword == matchedKeyword && other.index == index;

  @override
  int get hashCode => Object.hash(item, matchedKeyword, index);

  @override
  String toString() => 'CommandMatch($index, $item${matchedKeyword == null ? '' : ', keyword: "$matchedKeyword"'})';
}

/// A run of matches sharing a heading, in the order they should render.
class CommandGroup<T extends CommandDescriptor> {
  CommandGroup({this.group, required this.matches});

  /// The heading, or null for commands filed under none.
  final String? group;
  final List<CommandMatch<T>> matches;

  @override
  bool operator ==(Object other) {
    if (other is! CommandGroup || other.group != group || other.matches.length != matches.length) return false;
    for (var i = 0; i < matches.length; i++) {
      if (other.matches[i] != matches[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(group, Object.hashAll(matches));

  @override
  String toString() => 'CommandGroup($group, $matches)';
}

String _norm(String value) => value.trim().toLowerCase();

final RegExp _spaces = RegExp(r'\s+');
final RegExp _reSpecial = RegExp(r'[.*+?^${}()|[\]\\]');

String _escapeRe(String value) => value.replaceAllMapped(_reSpecial, (m) => '\\${m[0]}');

List<String> _terms(String query) => _norm(query).split(_spaces).where((term) => term.isNotEmpty).toList();

/// Longest keyword snippet worth surfacing as a row's match context.
const int _keywordSnippetMaxWords = 12;

/// The stretch of [keywords] worth showing as why a row matched.
///
/// A single term names just the word it hit. Several terms return the tightest run of words that holds them all, so
/// a phrase typed against long keyword text (a lyric, a description) surfaces the line it landed on rather than one
/// lonely word out of it, and the caller can highlight every term inside that run. Ellipses mark a snippet clipped
/// from a longer keyword string.
String? _keywordSnippet(String keywords, List<String> terms) {
  final words = keywords.split(_spaces).where((word) => word.isNotEmpty).toList();
  if (words.isEmpty) return null;

  final lower = words.map(_norm).toList();
  final present = terms.where((term) => lower.any((word) => word.contains(term))).toList();
  if (present.isEmpty) return null;
  if (present.length == 1) {
    final only = present.first;
    for (var i = 0; i < words.length; i++) {
      if (lower[i].contains(only)) return words[i];
    }
    return null;
  }

  // Minimum window over the words that contains an occurrence of every term.
  final seen = <String, int>{};
  var covered = 0;
  var left = 0;
  (int, int)? best;
  for (var right = 0; right < words.length; right++) {
    final wordRight = lower[right];
    for (final term in present) {
      if (wordRight.contains(term)) {
        final next = (seen[term] ?? 0) + 1;
        seen[term] = next;
        if (next == 1) covered += 1;
      }
    }
    while (covered == present.length) {
      if (best == null || right - left < best.$2 - best.$1) best = (left, right);
      final wordLeft = lower[left];
      for (final term in present) {
        if (wordLeft.contains(term)) {
          final next = (seen[term] ?? 0) - 1;
          seen[term] = next;
          if (next == 0) covered -= 1;
        }
      }
      left += 1;
    }
  }
  if (best == null) return null;

  final start = best.$1;
  final end = math.min(best.$2, start + _keywordSnippetMaxWords - 1);
  final snippet = words.sublist(start, end + 1).join(' ');
  return '${start > 0 ? '…' : ''}$snippet${end < words.length - 1 ? '…' : ''}';
}

/// How well a single term hit an item, lower being better, or null for a miss.
///
/// The tiers are about *where* the term landed, not how many characters it shares: "seek" should put SeekBar above
/// a component that merely lists seek as a keyword, and that is a fact about position, not a similarity score.
int? _rankTerm(CommandDescriptor item, String term) {
  final label = _norm(item.label);
  if (label.startsWith(term)) return 0;
  if (RegExp('\\b${_escapeRe(term)}').hasMatch(label)) return 1;
  if (label.contains(term)) return 2;
  if (_norm('${item.group ?? ''} ${item.keywords ?? ''}').contains(term)) return 3;
  return null;
}

/// A command that matched, with what it is sorted by: its worst term's tier (0 best, 3 group or keywords) and its
/// place in the caller's list.
class _Scored<T extends CommandDescriptor> {
  _Scored(this.item, this.rank, this.order, this.matchedKeyword);
  final T item;
  final int rank;
  final int order;
  final String? matchedKeyword;
}

/// Filters commands by a query, orders them by where the query hit, and stamps each survivor with its flat index.
///
/// Three rules, all chosen so a user can predict the result and a test can pin it:
///
/// - **Every whitespace-separated term must match somewhere.** Terms are ANDed across the label, group and
///   keywords, so "audio bar" finds a SeekBar tagged `audio` even though no single field contains that phrase.
/// - **Results are tiered by where the term landed**: label prefix, then a word start inside the label, then
///   anywhere in the label, then group or keywords. An item is ranked by its *worst* term, so a command has to be a
///   good match for the whole query rather than a great match for one word of it.
/// - **A band goes before the tiers** ([CommandDescriptor.band]): band 0's matches, tiered, then band 1's. Every row
///   is band 0 unless it says otherwise.
///
/// This is deliberately not fuzzy scoring. Ties keep the caller's order, so the caller still decides priority within
/// a tier. An empty query returns everything, in the given order.
List<CommandMatch<T>> matchCommands<T extends CommandDescriptor>(List<T> items, String query) {
  final terms = _terms(query);

  final scored = <_Scored<T>>[];

  for (var order = 0; order < items.length; order++) {
    final item = items[order];
    if (terms.isEmpty) {
      scored.add(_Scored(item, 0, order, null));
      continue;
    }

    var worst = 0;
    var missed = false;
    for (final term in terms) {
      final rank = _rankTerm(item, term);
      if (rank == null) {
        missed = true; // one miss drops the item
        break;
      }
      worst = math.max(worst, rank);
    }
    if (missed) continue;

    // Only worth naming when the label alone would not explain the hit: the row otherwise looks unrelated to what
    // the user typed.
    final matchedKeyword = terms.every((term) => _rankTerm(item, term) == 3) ? _keywordSnippet(item.keywords ?? '', terms) : null;

    scored.add(_Scored(item, worst, order, matchedKeyword));
  }

  scored.sort((a, b) {
    if (a.item.band != b.item.band) return a.item.band - b.item.band;
    return a.rank != b.rank ? a.rank - b.rank : a.order - b.order;
  });

  return [
    for (var index = 0; index < scored.length; index++) CommandMatch<T>(item: scored[index].item, matchedKeyword: scored[index].matchedKeyword, index: index),
  ];
}

/// Collects matches into their headings without reordering them.
///
/// Groups are formed from adjacent runs rather than gathered globally, so the caller's order always survives: a list
/// that interleaves groups renders interleaved instead of being silently rearranged. Each match keeps the flat index
/// it was given, so keyboard movement and visual order stay the same sequence even though the list is drawn in
/// sections.
List<CommandGroup<T>> groupCommands<T extends CommandDescriptor>(List<CommandMatch<T>> matches) {
  final groups = <CommandGroup<T>>[];
  for (final match in matches) {
    final last = groups.isEmpty ? null : groups.last;
    if (last != null && last.group == match.item.group) {
      last.matches.add(match);
    } else {
      groups.add(CommandGroup<T>(group: match.item.group, matches: [match]));
    }
  }
  return groups;
}

/// Where the cursor lands after a move, skipping disabled rows and wrapping at both ends: the movement every
/// palette has, so arrowing past the last row returns to the first instead of dead-ending.
///
/// Returns -1 when nothing is selectable, which is also the "no cursor" value, so an all-disabled list simply has
/// nowhere to be.
int moveCommandCursor<T extends CommandDescriptor>(List<CommandMatch<T>> matches, int from, int delta) {
  final count = matches.length;
  if (count == 0) return -1;

  // Walk at most one full lap; anything still disabled after that is a list with no runnable rows at all.
  final step = delta < 0 ? -1 : 1;
  var cursor = from;
  for (var i = 0; i < count; i += 1) {
    cursor = (((cursor + step) % count) + count) % count;
    if (!matches[cursor].item.disabled) return cursor;
  }
  return -1;
}

/// The first row the cursor should rest on for a fresh result set: used on open and after every keystroke, so the
/// top runnable command is always one Enter away.
int firstCommandCursor<T extends CommandDescriptor>(List<CommandMatch<T>> matches) => matches.indexWhere((match) => !match.item.disabled);

/// Whether a key event is the palette's summon chord: ⌘K on Apple platforms, Ctrl+K everywhere else. Both are
/// accepted on both, because a user who learned one should not find it dead on the other machine.
bool isCommandShortcut({required String key, bool metaKey = false, bool ctrlKey = false}) => (metaKey || ctrlKey) && key.toLowerCase() == 'k';

/// One run of a label, flagged for whether the query put it there.
class CommandSegment {
  const CommandSegment({required this.text, required this.match});

  final String text;

  /// True when this run is part of why the row matched.
  final bool match;

  @override
  bool operator ==(Object other) => other is CommandSegment && other.text == text && other.match == match;

  @override
  int get hashCode => Object.hash(text, match);

  @override
  String toString() => 'CommandSegment("$text", match: $match)';
}

/// `String.prototype.slice` for non-negative bounds: out-of-range ends are clamped, never thrown.
String _slice(String text, int start, [int? end]) {
  final to = math.min(end ?? text.length, text.length);
  final from = math.min(start, to);
  return text.substring(from, to);
}

/// Splits a label into matched and unmatched runs so a row can show the user exactly which characters answered
/// their query.
///
/// Term-wise, not query-wise, because matching is: [matchCommands] ANDs the whitespace-separated terms across
/// separate fields, so "rich text" can hit a label that never contains that phrase contiguously. Each term is marked
/// wherever it lands instead.
///
/// Overlapping and adjacent hits are merged, so "text textarea" marks one run rather than painting a seam through a
/// word. Returns a single unmatched segment when the query is empty or nothing lands, so callers can render the
/// result unconditionally.
List<CommandSegment> highlightSegments(String text, String query) {
  final terms = _terms(query);
  if (terms.isEmpty || text.isEmpty) return [CommandSegment(text: text, match: false)];

  final haystack = text.toLowerCase();
  final ranges = <List<int>>[];
  for (final term in terms) {
    // Every occurrence, not just the first: a term can legitimately appear more than once in one label, and marking
    // only the first reads as a near-miss.
    var from = 0;
    for (;;) {
      final at = haystack.indexOf(term, from);
      if (at == -1) break;
      ranges.add([at, at + term.length]);
      from = at + term.length;
    }
  }
  if (ranges.isEmpty) return [CommandSegment(text: text, match: false)];

  ranges.sort((a, b) => a[0] - b[0]);
  final merged = <List<int>>[];
  for (final range in ranges) {
    final start = range[0], end = range[1];
    final last = merged.isEmpty ? null : merged.last;
    // `<=` merges touching runs as well as overlapping ones, so two terms that meet exactly do not leave a
    // zero-width unmatched segment between them.
    if (last != null && start <= last[1]) {
      last[1] = math.max(last[1], end);
    } else {
      merged.add([start, end]);
    }
  }

  final segments = <CommandSegment>[];
  var cursor = 0;
  for (final range in merged) {
    final start = range[0], end = range[1];
    if (start > cursor) segments.add(CommandSegment(text: _slice(text, cursor, start), match: false));
    segments.add(CommandSegment(text: _slice(text, start, end), match: true));
    cursor = end;
  }
  if (cursor < text.length) segments.add(CommandSegment(text: _slice(text, cursor), match: false));
  return segments;
}
