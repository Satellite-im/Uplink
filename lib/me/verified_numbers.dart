import 'dart:async';

import 'package:flutter/foundation.dart';

import 'me.dart';

/// The verified-number badge (Matt, 2026-11-19: "add the verfied by number badge as a default feature"): a mark beside
/// someone in a space or a circle who verified a phone number by a code texted to it. Only the relay knows who did
/// (relay/lib/handles.dart, `badges`), and it says yes or no, never the number; a person's app can't claim it for
/// them. Asked for in batches as faces come on screen, kept for a while, and asked again after.
///
/// Someone is known by their id on the hub and, where they said it, their username: a computer paired with a phone
/// has an id of its own, so the username is what carries the phone's badge to the computer's messages.
class VerifiedNumbers extends ChangeNotifier {
  VerifiedNumbers({Future<({Set<String> ids, Set<String> names})> Function(List<String> ids, List<String> names)? ask, this.keep = const Duration(minutes: 30)})
      : _ask = ask ?? ((ids, names) => Me.instance.badges(ids, names));

  static VerifiedNumbers instance = VerifiedNumbers();

  final Future<({Set<String> ids, Set<String> names})> Function(List<String> ids, List<String> names) _ask;

  /// How long an answer stands before it is asked again.
  final Duration keep;

  /// Answers: by `i:<id>` and `u:<username>`, whether they have the badge and when that was learned.
  final Map<String, ({bool yes, DateTime at})> _known = {};
  final Set<String> _wantIds = {}, _wantNames = {};
  bool _soon = false;

  /// When asking last failed (the relay out of reach): nothing is asked again for [backOff] after.
  DateTime? _failedAt;
  static const backOff = Duration(seconds: 30);

  /// Whether [id] (or the person with [username]) has the badge: yes, no, or null while not known yet, in which case
  /// it is asked for, with others wanted about now.
  bool? of(String id, {String? username}) {
    final u = username == null || username.isEmpty ? null : username.toLowerCase();
    final byId = _fresh('i:$id'), byName = u == null ? null : _fresh('u:$u');
    if (byId == true || byName == true) return true;
    if (byId == null && id.isNotEmpty) _want(ids: [id]);
    if (u != null && byName == null) _want(names: [u]);
    if (byId == false && (u == null || byName == false)) return false;
    return null;
  }

  /// Whether this person verified their own number (Settings › Me), for their own messages.
  bool get mine => (Me.instance.number ?? '').isNotEmpty;

  /// The answer kept under [key], while it is no older than [keep]; null where there is none or it has gone stale.
  bool? _fresh(String key) {
    final k = _known[key];
    if (k == null || DateTime.now().difference(k.at) > keep) return null;
    return k.yes;
  }

  /// Gathers what the faces drawn about now want, and asks once for all of them after this turn of drawing (a
  /// microtask, not a timer: nothing is left waiting behind a screen that has gone).
  void _want({List<String> ids = const [], List<String> names = const []}) {
    final failed = _failedAt;
    if (failed != null && DateTime.now().difference(failed) < backOff) return;
    _wantIds.addAll(ids);
    _wantNames.addAll(names);
    if (_soon) return;
    _soon = true;
    scheduleMicrotask(_askNow);
  }

  Future<void> _askNow() async {
    _soon = false;
    final ids = _wantIds.take(64).toList(), names = _wantNames.take(64).toList();
    _wantIds.removeAll(ids);
    _wantNames.removeAll(names);
    if (ids.isEmpty && names.isEmpty) return;
    // Marked as asked now, so a face drawn again meanwhile doesn't ask again; told for real when the answer comes.
    final now = DateTime.now();
    try {
      final got = await _ask(ids, names);
      for (final i in ids) {
        _known['i:$i'] = (yes: got.ids.contains(i), at: now);
      }
      for (final n in names) {
        _known['u:$n'] = (yes: got.names.contains(n), at: now);
      }
      _failedAt = null;
      notifyListeners();
    } catch (_) {
      // The relay out of reach: asked again after [backOff], by whichever face is drawn then.
      _failedAt = DateTime.now();
      _wantIds.clear();
      _wantNames.clear();
      return;
    }
    if (_wantIds.isNotEmpty || _wantNames.isNotEmpty) {
      _soon = true;
      scheduleMicrotask(_askNow);
    }
  }

  /// Forgets everything known (a test, or signing out).
  @visibleForTesting
  void reset() {
    _soon = false;
    _failedAt = null;
    _known.clear();
    _wantIds.clear();
    _wantNames.clear();
  }
}
