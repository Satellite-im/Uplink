import 'dart:async';
import 'dart:convert';

import 'forward_secrecy.dart' show FsStore;
import 'switchboard.dart' show RouteUse, Switchboard;

/// Which route last carried something to each person, and which brought something from them, kept from one run of the
/// app to the next (GMFB-24: "Settings › Network shows which route each conversation is using"; checked against the
/// code on 2026-11-25: "per person, not per conversation, and forgets on close"). What the switchboard saw
/// (Switchboard.used) is written a few seconds after it changes and as the app is put away, and read back as the
/// routes are set up, so Settings › Routes says how each conversation last went before anything is sent again.
///
/// One small file, out of any backup, beside the ledger's (kept_files.dart): for each person their install's name, the
/// two routes' names and the two times. No word of any message, and nothing a relay doesn't already see. Kept for a
/// week, for the account it was written under and no other, and deleted at sign-out ([wipe], [forget]).
class RoutesKept {
  RoutesKept({required this.store, required this.me, DateTime Function()? now, this.after = const Duration(seconds: 8)}) : _now = now ?? DateTime.now;

  final FsStore store;

  /// The account this is kept for: what was written under another is not read.
  final String me;
  final DateTime Function() _now;

  /// How long after a change it is written.
  final Duration after;

  /// The file's name, and how long a person's routes are kept after anything last went or came.
  static const name = 'used', keepFor = Duration(days: 7);

  static final _id = RegExp(r'^[0-9a-f]{32}$'), _route = RegExp(r'^[a-z0-9]{1,12}$');

  Map<String, RouteUse> Function()? _source;
  Timer? _timer;
  bool _wiped = false;
  Future<void> _last = Future.value();

  /// What was kept, for this account: each person's routes, the longest quiet first. Nothing where there is none, it
  /// was another account's, or it can't be read; a person not sent to or heard from in [keepFor] is left out.
  Future<Map<String, RouteUse>> read() async {
    try {
      final raw = await store.read(name);
      if (raw == null || raw.isEmpty) return {};
      final j = jsonDecode(raw);
      if (j is! Map || j['v'] != 1 || j['me'] != me || j['u'] is! Map) return {};
      final now = _now();
      final out = <String, RouteUse>{};
      DateTime? when(Object? ms) => ms is int && ms > 0 ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
      for (final e in (j['u'] as Map).entries) {
        final id = e.key, v = e.value;
        if (id is! String || !_id.hasMatch(id) || v is! List || v.length != 4) continue;
        final sentBy = v[0] is String && _route.hasMatch(v[0] as String) ? v[0] as String : null;
        final cameBy = v[2] is String && _route.hasMatch(v[2] as String) ? v[2] as String : null;
        final sentAt = sentBy == null ? null : when(v[1]), cameAt = cameBy == null ? null : when(v[3]);
        final use = RouteUse(sentBy: sentAt == null ? null : sentBy, sentAt: sentAt, cameBy: cameAt == null ? null : cameBy, cameAt: cameAt);
        if (use.sentAt == null && use.cameAt == null) continue;
        // Older than a week, or from a clock that was a day ahead: not kept.
        if (now.difference(use.last) > keepFor || use.last.difference(now) > const Duration(days: 1)) continue;
        out[id] = use;
      }
      final sorted = out.entries.toList()..sort((a, b) => a.value.last.compareTo(b.value.last));
      final kept = sorted.length > Switchboard.mostUsed ? sorted.sublist(sorted.length - Switchboard.mostUsed) : sorted;
      return {for (final e in kept) e.key: e.value};
    } catch (_) {
      return {};
    }
  }

  /// What is to be kept changed: [used] is asked for it and it is written, [after] from now (many changes, one write).
  void changed(Map<String, RouteUse> Function() used) {
    _source = used;
    if (_wiped) return;
    _timer ??= Timer(after, () {
      _timer = null;
      unawaited(flush());
    });
  }

  /// Writes what is to be kept now (the app is put away, or closing), where anything changed since it was last written.
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    final source = _source;
    _source = null;
    if (source == null || _wiped) return _last;
    final run = _last.then((_) async {
      if (_wiped) return;
      final cut = _now().subtract(keepFor);
      await store.write(
        name,
        jsonEncode({
          'v': 1,
          'me': me,
          'u': {
            for (final e in source().entries)
              if (e.value.last.isAfter(cut)) e.key: [e.value.sentBy, e.value.sentAt?.millisecondsSinceEpoch, e.value.cameBy, e.value.cameAt?.millisecondsSinceEpoch],
          },
        }),
      );
    });
    _last = run.then<void>((_) {}, onError: (Object _) {});
    return _last;
  }

  /// Deletes what is kept, and keeps nothing more: signing out.
  Future<void> wipe() async {
    _wiped = true;
    _timer?.cancel();
    _timer = null;
    _source = null;
    await _last;
    await forget(store);
  }

  /// Deletes what one of these kept in [store], where none is running to [wipe] itself.
  static Future<void> forget(FsStore store) => store.write(name, '');

  /// Stops without writing: the routes are gone.
  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
