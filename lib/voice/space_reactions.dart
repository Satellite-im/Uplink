import 'package:flutter/foundation.dart';

import '../reactions.dart' show isEmojiRun;

/// Reactions to messages in a space's or a circle's chat (Matt, 2026-11-20: "add reactions after done to spaces and
/// circles"): who put which emoji on which message, as the room said it.
///
/// Each person's each emoji on a message is on or off, with when that was said, and the newest word wins (so a
/// reaction taken off and put back on, said in any order or said again by the hub's kept packets, ends as it was last
/// left). Said in the room as `react` (`id` the message, `e` the emoji, `on`, `at`), sent apart from other packets where
/// the relay takes reactions (relay/lib/hub.dart toRoomReaction) so that someone who may not post in a read-only space
/// may still react; a device coming in is handed them with the history (`reacts`).
@immutable
class ReactionSay {
  const ReactionSay({required this.on, required this.at});
  final bool on;
  final int at;
}

/// One emoji on one message, as drawn: how many put it there, whether this person did, and who.
typedef ReactionTally = ({String emoji, int count, bool mine, List<String> who});

/// Every reaction one space's chat has heard, held by its HangoutRoom: takes what is said, and counts it for drawing.
class SpaceReactions {
  /// By message id, then person, then emoji.
  final Map<String, Map<String, Map<String, ReactionSay>>> _all = {};

  /// At most this many messages' reactions are kept, the newest said first.
  static const messagesKept = 400;

  /// At most this many kinds of emoji on one message from one person.
  static const perPerson = 20;

  bool get isEmpty => _all.isEmpty;

  /// Takes [person]'s word that [emoji] is [on] [message] at [at]; true where it changed anything.
  bool take(String message, String person, String emoji, {required bool on, required int at}) {
    if (message.isEmpty || person.isEmpty || !isEmojiRun(emoji, max: 12)) return false;
    final byPerson = _all.putIfAbsent(message, () => {});
    final mine = byPerson.putIfAbsent(person, () => {});
    final had = mine[emoji];
    if (had != null && had.at >= at) return false;
    // Over the limit a new emoji is refused; one already there can still be changed.
    if (had == null && mine.length >= perPerson && on) return false;
    mine[emoji] = ReactionSay(on: on, at: at);
    // Most recently touched last, so the oldest go first.
    _all.remove(message);
    _all[message] = byPerson;
    while (_all.length > messagesKept) {
      _all.remove(_all.keys.first);
    }
    return had?.on != on;
  }

  /// Whether [person] has [emoji] on [message] now.
  bool has(String message, String person, String emoji) => _all[message]?[person]?[emoji]?.on ?? false;

  /// [message]'s reactions, in the order they were first put there, with [me]'s marked. [same] tells whether two ids are
  /// one person (a phone and its computer).
  List<ReactionTally> of(String message, String me, {bool Function(String a, String b)? same}) {
    final byPerson = _all[message];
    if (byPerson == null) return const [];
    final first = <String, int>{};
    final who = <String, List<String>>{};
    for (final p in byPerson.entries) {
      for (final e in p.value.entries) {
        if (!e.value.on) continue;
        final at = first[e.key];
        if (at == null || e.value.at < at) first[e.key] = e.value.at;
        (who[e.key] ??= []).add(p.key);
      }
    }
    final order = first.keys.toList()..sort((a, b) => first[a]!.compareTo(first[b]!));
    return [
      for (final e in order) (emoji: e, count: who[e]!.length, mine: who[e]!.any((id) => id == me || (same?.call(id, me) ?? false)), who: who[e]!),
    ];
  }

  /// What [ids]' reactions are, as a `reacts` answer and the device's store carry them: message, person, emoji, then
  /// `[on ? 1 : 0, at]`.
  Map<String, Object> toJson([Iterable<String>? ids]) => {
        for (final m in _all.entries)
          if (ids == null || ids.contains(m.key))
            m.key: {
              for (final p in m.value.entries) p.key: {for (final e in p.value.entries) e.key: [e.value.on ? 1 : 0, e.value.at]},
            },
      };

  /// Takes everything [j] says; true where anything changed. [may] says whose words are taken.
  bool takeAll(Object? j, {bool Function(String person)? may}) {
    if (j is! Map) return false;
    var any = false;
    for (final m in j.entries.take(messagesKept)) {
      if (m.key is! String || m.value is! Map) continue;
      for (final p in (m.value as Map).entries) {
        if (p.key is! String || p.value is! Map || !(may?.call(p.key as String) ?? true)) continue;
        for (final e in (p.value as Map).entries.take(perPerson)) {
          final v = e.value;
          if (e.key is! String || v is! List || v.length != 2 || v[1] is! int) continue;
          any = take(m.key as String, p.key as String, e.key as String, on: v[0] == 1, at: v[1] as int) || any;
        }
      }
    }
    return any;
  }
}
