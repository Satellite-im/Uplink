import 'package:flutter/foundation.dart';

/// Polls in a space's chat (Matt, 2026-11-19: "add Polls as a default feature"): a question with two to ten answers,
/// asked as a message ([PollSpec], the message's words the question), and answered by everyone who may write there.
///
/// **On the wire** a poll is a message with `pl`: `{o: [answers], m: 1 where more than one may be chosen}`; a build
/// from before shows its `x`, "📊 Poll" and the question. A vote is `{t: vote, p: poll id, c: [chosen answers'
/// indexes], at}`, kept by the hub for whoever comes later, and every vote so far goes in a `votes` answer to a
/// `sync?`. Each person's latest vote is theirs; an empty one takes theirs back. The counting is done here, on each
/// device, from the votes it has: no server counts anything.
@immutable
class PollSpec {
  const PollSpec({required this.options, this.multi = false});

  /// The answers, in their order; [least] to [most] of them, none empty, none longer than [optionMost].
  final List<String> options;

  /// Whether more than one answer may be chosen.
  final bool multi;

  // How many answers a poll may have, and the most characters in an answer and in the question.
  static const least = 2;
  static const most = 10;
  static const optionMost = 80;
  static const questionMost = 300;

  Map<String, Object> toJson() => {'o': options, if (multi) 'm': 1};

  /// From what came, or null where it is not a poll this app can show.
  static PollSpec? fromJson(Object? j) {
    if (j is! Map || j['o'] is! List) return null;
    final options = [
      for (final o in (j['o'] as List).take(most))
        if (o is String && o.trim().isNotEmpty) o.trim().length > optionMost ? o.trim().substring(0, optionMost) : o.trim(),
    ];
    if (options.length < least) return null;
    return PollSpec(options: options, multi: j['m'] == 1);
  }

  /// [options] as written, tidied: blank ones left out, each cut to [optionMost], no more than [most]; null where
  /// fewer than [least] are left.
  static PollSpec? of(List<String> options, {bool multi = false}) {
    final kept = [
      for (final o in options)
        if (o.trim().isNotEmpty) o.trim().length > optionMost ? o.trim().substring(0, optionMost) : o.trim(),
    ].take(most).toList();
    return kept.length < least ? null : PollSpec(options: kept, multi: multi);
  }

  @override
  bool operator ==(Object other) => other is PollSpec && other.multi == multi && listEquals(other.options, options);

  @override
  int get hashCode => Object.hash(multi, Object.hashAll(options));
}

/// One person's vote: the answers they chose (their indexes) and when.
@immutable
class PollVote {
  const PollVote(this.choices, this.at);
  final List<int> choices;
  final int at;

  List<Object> toJson() => [choices, at];

  /// From `[choices, at]`; null where it is not that. The choices are not yet checked against a poll ([valid]).
  static PollVote? fromJson(Object? j) {
    if (j is! List || j.length != 2 || j[0] is! List || j[1] is! int) return null;
    return PollVote([for (final c in j[0] as List) if (c is int) c], j[1] as int);
  }

  /// [choices] as a poll of [spec] allows them: each an answer it has, once, and only one where it is not [PollSpec.multi].
  static List<int> valid(PollSpec spec, Iterable<int> choices) {
    final out = <int>[];
    for (final c in choices) {
      if (c < 0 || c >= spec.options.length || out.contains(c)) continue;
      out.add(c);
      if (!spec.multi) break;
    }
    return out..sort();
  }
}

/// A poll's answers counted: how many chose each, how many voted, and what this device's person chose.
@immutable
class PollTally {
  const PollTally({required this.counts, required this.voters, required this.mine});
  final List<int> counts;
  final int voters;
  final List<int> mine;

  /// The share of [voters] who chose answer [i], from 0 to 1.
  double share(int i) => voters == 0 ? 0 : counts[i] / voters;
}

/// Counts [votes] (voter's id to their vote) for a poll of [spec]: each person once, however many of their devices
/// voted ([personOf]: a voter's id to who they are, their username where known), their latest vote theirs; [me] is
/// this device's person.
PollTally tallyPoll(PollSpec spec, Map<String, PollVote> votes, {required String Function(String id) personOf, required String me}) {
  final latest = <String, PollVote>{};
  for (final e in votes.entries) {
    final who = personOf(e.key);
    final had = latest[who];
    if (had == null || e.value.at > had.at) latest[who] = e.value;
  }
  final counts = List<int>.filled(spec.options.length, 0);
  var voters = 0;
  for (final v in latest.values) {
    final chosen = PollVote.valid(spec, v.choices);
    if (chosen.isEmpty) continue;
    voters++;
    for (final c in chosen) {
      counts[c]++;
    }
  }
  final mine = latest[personOf(me)];
  return PollTally(counts: counts, voters: voters, mine: mine == null ? const [] : PollVote.valid(spec, mine.choices));
}
