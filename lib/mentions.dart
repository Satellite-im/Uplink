/// Mentions in a space's chat (Matt, 2026-11-19: "Add mentions support to spaces and circles with the @user prefix").
///
/// Writing "@" in a space's chat offers the space's people; the one picked goes into the words as "@Name", and the
/// message says beside its words who was meant ([Mention]: where in the words the name is, and that person's id). So
/// the words read the same on a build from before mentions ("@Maya are you coming?"), a name two people share still
/// means the one who was picked, and whoever reads it guesses nothing from the words.
///
/// - [Mention], [Mention.checked]: what a message carries, and how much of it is believed.
/// - [MentionQuery.at]: the "@…" being written where the cursor is.
/// - [MentionPerson], [matchMentions]: who is offered for it, and in what order.
/// - [MentionEdit.of]: what becomes of the mentions already in the composer's words as the words are edited.
///
/// Nothing here draws anything or knows of a space: lib/voice/hangout.dart carries them, lib/ui/mention_field.dart
/// writes them and lib/ui/mention_text.dart draws them.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// One "@Name" in a message's words, and who it means.
@immutable
class Mention {
  const Mention(this.start, this.length, this.id);

  /// Where its "@Name" begins in the message's words and how long it is, counted in UTF-16 code units: a Dart
  /// string's own, so the same number on every device the app runs on (an emoji before it counts as two).
  final int start;
  final int length;

  /// Who is meant: their id on the hub (NetCrypto.idOf), as a message's sender is named.
  final String id;

  int get end => start + length;

  /// The most mentions one message carries, and the longest a mention's words may be ("@" and a name).
  static const most = 30;
  static const longest = 81;


  /// What an id may be made of: nothing else is taken from the wire as one.
  static final _id = RegExp(r'^[0-9A-Za-z_.:-]{1,64}$');

  /// The same mention [by] code units further on in the words (earlier, where [by] is below zero).
  Mention moved(int by) => Mention(start + by, length, id);

  /// On the wire, `[start, length, id]`.
  List<Object> toJson() => [start, length, id];

  /// [mentions] as far as they can be believed of [text]: each inside the words, on one line, beginning at an "@",
  /// naming an id that could be one, not ending between the two halves of a character, none over another, in order,
  /// and [most] at the most. The others are left out and the words still say what they say: a mention that names
  /// someone the words do not show is never taken, since it would call them without anyone seeing it.
  static List<Mention> checked(Iterable<Mention> mentions, String text) {
    final sorted = [...mentions]..sort((a, b) => a.start != b.start ? a.start.compareTo(b.start) : a.length.compareTo(b.length));
    final kept = <Mention>[];
    var from = 0;
    for (final m in sorted) {
      if (kept.length >= most) break;
      if (m.start < from || m.length < 2 || m.length > longest || m.end > text.length || !_id.hasMatch(m.id)) continue;
      if (text.codeUnitAt(m.start) != 0x40) continue;
      if (m.end < text.length && _lowHalf(text.codeUnitAt(m.end)) && _highHalf(text.codeUnitAt(m.end - 1))) continue;
      final words = text.substring(m.start, m.end);
      if (words.contains('\n') || words.trim().length != words.length) continue;
      kept.add(m);
      from = m.end;
    }
    return kept;
  }

  /// From a message's `mn`, checked against its words ([checked]); what can't be read is passed over.
  static List<Mention> listFromJson(Object? j, String text) {
    if (j is! List) return const [];
    return checked([
      // No more looked at than could ever be kept, however long a list is sent.
      for (final e in j.take(most * 4))
        if (e is List && e.length == 3 && e[0] is int && e[1] is int && e[2] is String) Mention(e[0] as int, e[1] as int, e[2] as String),
    ], text);
  }

  /// [mentions], written against [text] as the composer holds it, against its words as they are sent: without the
  /// space at either end ([String.trim], which the sending does too).
  static List<Mention> trimmed(Iterable<Mention> mentions, String text) {
    final words = text.trim();
    final lead = text.length - text.trimLeft().length;
    return checked([for (final m in mentions) m.moved(-lead)], words);
  }

  /// Whether any of [mentions] means [id].
  static bool names(Iterable<Mention> mentions, String id) => mentions.any((m) => m.id == id);

  @override
  bool operator ==(Object other) => other is Mention && other.start == start && other.length == length && other.id == id;

  @override
  int get hashCode => Object.hash(start, length, id);

  @override
  String toString() => 'Mention($start+$length $id)';
}

/// The two halves of a character outside the basic plane (an emoji), as UTF-16 writes it: a surrogate pair.
bool _highHalf(int unit) => unit >= 0xD800 && unit <= 0xDBFF;
bool _lowHalf(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

/// The "@…" being written where the cursor is: what the list of people is narrowed by.
@immutable
class MentionQuery {
  const MentionQuery(this.start, this.text);

  /// Where its "@" is in the words, and what is written after it up to the cursor ("" just after the "@").
  final int start;
  final String text;

  /// Where the cursor is: the end of what a pick replaces.
  int get end => start + 1 + text.length;

  /// The longest a query is followed for: a name is not longer.
  static const longest = 40;

  /// What may not stand just before the "@": a letter, a digit or what joins the parts of an address, so the "@" of
  /// "maya@example.com" or of a link starts nothing.
  static final _joined = RegExp(r'[\p{L}\p{N}_.@/:+\-]', unicode: true);

  /// The query at [cursor] in [words], or null where there is none: the nearest "@" before the cursor on the same
  /// line, standing at the start of a word, with something other than a space after it, and not already one of
  /// [mentions] (the cursor just after a mention picked is not a query for it again).
  ///
  /// A name can be of several words ("Maya Chen"), so a space does not end the query: it goes on for as long as it
  /// still finds someone ([matchMentions]), and the list closes by itself once it finds nobody.
  static MentionQuery? at(String words, int cursor, {Iterable<Mention> mentions = const []}) {
    if (cursor < 1 || cursor > words.length) return null;
    for (var i = cursor - 1; i >= 0 && cursor - i <= longest + 1; i--) {
      final unit = words.codeUnitAt(i);
      if (unit == 0x0A || unit == 0x0D) return null;
      if (unit != 0x40) continue;
      if (i > 0) {
        final two = i > 1 && _lowHalf(words.codeUnitAt(i - 1)) && _highHalf(words.codeUnitAt(i - 2));
        if (_joined.hasMatch(words.substring(two ? i - 2 : i - 1, i))) return null;
      }
      final text = words.substring(i + 1, cursor);
      if (text.isNotEmpty && text.trimLeft().length != text.length) return null;
      // The cursor in or after a mention already made, or an "@" inside one, is no query.
      if (mentions.any((m) => i >= m.start && i < m.end)) return null;
      return MentionQuery(i, text);
    }
    return null;
  }

  @override
  bool operator ==(Object other) => other is MentionQuery && other.start == start && other.text == text;

  @override
  int get hashCode => Object.hash(start, text);

  @override
  String toString() => 'MentionQuery($start "$text")';
}

/// Someone who can be mentioned in a space, as the list offers them.
@immutable
class MentionPerson {
  const MentionPerson({required this.id, required this.name, this.username, this.here = false, this.last = 0, this.role});

  final String id;

  /// The name they go by here: what goes into the words after the "@".
  final String name;
  final String? username;

  /// In the space now.
  final bool here;

  /// When they last wrote in it (ms since 1970); 0 where this device has nothing of theirs.
  final int last;

  /// Their role in the space, for the colour of their name; null where it has none to show.
  final Object? role;

  /// The name as it is written into a message: on one line, no space at its ends, not longer than a mention may be.
  static String written(String name) {
    final one = name.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (one.length <= Mention.longest - 1) return one;
    var cut = Mention.longest - 1;
    // Not between the two halves of a character.
    if (_lowHalf(one.codeUnitAt(cut)) && _highHalf(one.codeUnitAt(cut - 1))) cut--;
    return one.substring(0, cut).trimRight();
  }
}

/// The people of [people] that [query] (what is written after the "@") finds, best first, [most] at the most.
///
/// Whoever's name begins with it comes first, then whoever has a later word of their name or their username
/// beginning with it, then (from two letters on) whoever has it anywhere in either. Among those alike: people here
/// now, then whoever wrote here last, then by name. Capitals are not told apart. An empty query finds everyone.
List<MentionPerson> matchMentions(String query, Iterable<MentionPerson> people, {int most = 8}) {
  final q = query.toLowerCase();
  final found = <(int, MentionPerson)>[];
  for (final p in people) {
    final name = p.name.toLowerCase();
    if (name.isEmpty) continue;
    final user = (p.username ?? '').toLowerCase();
    final int rank;
    if (q.isEmpty || name.startsWith(q)) {
      rank = 0;
    } else if (user.startsWith(q) || name.split(' ').skip(1).any((w) => w.startsWith(q))) {
      rank = 1;
    } else if (q.length >= 2 && (name.contains(q) || user.contains(q))) {
      rank = 2;
    } else {
      continue;
    }
    found.add((rank, p));
  }
  found.sort((a, b) {
    if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
    if (a.$2.here != b.$2.here) return a.$2.here ? -1 : 1;
    if (a.$2.last != b.$2.last) return b.$2.last.compareTo(a.$2.last);
    final byName = a.$2.name.toLowerCase().compareTo(b.$2.name.toLowerCase());
    return byName != 0 ? byName : a.$2.id.compareTo(b.$2.id);
  });
  return [for (final f in found.take(most)) f.$2];
}

/// What became of the mentions in the composer's words when the words changed.
///
/// A mention before the change stays where it is, one after it moves along with the words, and one the change went
/// into is a mention no longer: its letters stay as plain words. Deleting into a mention takes the whole of it, as
/// the other chat apps do ([text] and [cursor] then say what the words should be instead of what was asked).
@immutable
class MentionEdit {
  const MentionEdit(this.mentions, {this.text, this.cursor});

  /// The mentions as they are in the words now.
  final List<Mention> mentions;

  /// Where a deletion took part of a mention: the words with all of it gone, and where the cursor then stands.
  final String? text;
  final int? cursor;

  /// The stretch of [was] that was replaced and the stretch of [now] it became. Where the cursor was ([wasStart] to
  /// [wasEnd]) and is ([nowCursor]) are used where they explain the change exactly (a letter typed, a selection
  /// typed over, a backspace, a forward delete): "@Anna" then "a" typed after it and "a" typed inside it make the same
  /// words, and only the cursor says which. Otherwise it is whatever lies between what the two have in common at
  /// each end.
  static ({int start, int oldEnd, int newEnd}) region(String was, String now, {int? wasStart, int? wasEnd, int? nowCursor}) {
    if (wasStart != null && wasEnd != null && nowCursor != null && wasStart >= 0 && wasEnd >= wasStart && wasEnd <= was.length && nowCursor >= 0 && nowCursor <= now.length) {
      final start = math.min(wasStart, nowCursor);
      if (now.length - nowCursor == was.length - wasEnd && now.substring(0, start) == was.substring(0, start) && now.substring(nowCursor) == was.substring(wasEnd)) {
        return (start: start, oldEnd: wasEnd, newEnd: nowCursor);
      }
      final gone = was.length - now.length;
      if (wasStart == wasEnd && nowCursor == wasStart && gone > 0 && now.substring(0, wasStart) == was.substring(0, wasStart) && now.substring(wasStart) == was.substring(wasStart + gone)) {
        return (start: wasStart, oldEnd: wasStart + gone, newEnd: wasStart);
      }
    }
    final most = math.min(was.length, now.length);
    var head = 0;
    while (head < most && was.codeUnitAt(head) == now.codeUnitAt(head)) {
      head++;
    }
    var tail = 0;
    while (tail < most - head && was.codeUnitAt(was.length - 1 - tail) == now.codeUnitAt(now.length - 1 - tail)) {
      tail++;
    }
    return (start: head, oldEnd: was.length - tail, newEnd: now.length - tail);
  }

  /// [mentions], written against [was], as they are once the words are [now].
  static MentionEdit of(List<Mention> mentions, {required String was, required String now, int? wasStart, int? wasEnd, int? nowCursor}) {
    if (mentions.isEmpty || was == now) return MentionEdit(mentions);
    final r = region(was, now, wasStart: wasStart, wasEnd: wasEnd, nowCursor: nowCursor);
    bool touched(Mention m) => m.start < r.oldEnd && m.end > r.start;
    final hit = [for (final m in mentions) if (touched(m)) m];
    // Only a deletion: where it stops part way into a mention, the whole mention goes with it.
    if (r.newEnd == r.start && r.oldEnd > r.start && hit.any((m) => m.start < r.start || m.end > r.oldEnd)) {
      final from = hit.fold(r.start, (int at, m) => math.min(at, m.start));
      final to = hit.fold(r.oldEnd, (int at, m) => math.max(at, m.end));
      return MentionEdit(
        [for (final m in mentions) if (m.end <= from) m else if (m.start >= to) m.moved(from - to)],
        text: was.substring(0, from) + was.substring(to),
        cursor: from,
      );
    }
    final by = now.length - was.length;
    return MentionEdit([for (final m in mentions) if (m.end <= r.start) m else if (m.start >= r.oldEnd) m.moved(by)]);
  }
}
