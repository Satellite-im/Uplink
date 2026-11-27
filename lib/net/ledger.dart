import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'carrier.dart';
import 'forward_secrecy.dart' show FsStore;
import 'hub_carrier.dart';
import 'p2p/p2p.dart';
import 'packet.dart';
import 'switchboard.dart';

/// What makes a timer: `Timer.new`, or a test's clock.
typedef LedgerTimer = Timer Function(Duration after, void Function() then);

/// What the relay got wrong, as a comparison over a direct link found it (docs/OPEN_NETWORK.md, section 3).
enum LedgerWrongKind {
  /// It said it passed a friend's message on to this device, which was connected to it then, and the message never came.
  passed,

  /// It said it kept a friend's message for this device and never handed it over. Not put down for now (the review,
  /// D3): the relay hands what it kept to whichever of the account's devices signs in first, and nothing here can yet
  /// prove no other did. Kept for what an earlier build wrote.
  kept,

  /// It told a friend's device that this device was away when its message came, while this device was connected to it.
  away,

  /// It said a friend was gone while their device said it was connected to the same relay.
  gone,
}

/// One thing the relay got wrong: what, when (by this device's clock, in milliseconds), and with which friend.
@immutable
class LedgerWrong {
  const LedgerWrong(this.kind, this.at, this.friend);
  final LedgerWrongKind kind;
  final int at;
  final String friend;

  List<Object> toJson() => [kind.name, at, friend];

  static LedgerWrong? fromJson(Object? j) {
    if (j is! List || j.length < 3 || j[0] is! String || j[1] is! int || j[2] is! String) return null;
    final kind = LedgerWrongKind.values.asNameMap()[j[0]];
    return kind == null ? null : LedgerWrong(kind, j[1] as int, j[2] as String);
  }
}

/// Something sent to a friend, as the ledger keeps it: its envelope's name, when the route whose word is kept took it,
/// that route, whether it said it kept it for them (else that it passed it on), whether they answered, and whether a
/// device of theirs has said, comparing, that it came.
class LedgerSent {
  LedgerSent(this.id, this.at, this.via, {this.kept = false, this.answered = false, this.matched = false});
  final String id;
  int at;
  String via;
  bool kept, answered, matched;

  List<Object> toJson() => [id, at, via, (kept ? 1 : 0) | (answered ? 2 : 0) | (matched ? 4 : 0)];

  static LedgerSent? fromJson(Object? j) {
    if (j is! List || j.length < 4 || j[0] is! String || j[1] is! int || j[2] is! String || j[3] is! int) return null;
    final f = j[3] as int;
    return LedgerSent(j[0] as String, j[1] as int, j[2] as String, kept: f & 1 != 0, answered: f & 2 != 0, matched: f & 4 != 0);
  }
}

/// Something that came from a friend: its envelope's name, when, by which route, and whether a device of theirs has
/// said, comparing, that it sent it.
class LedgerGot {
  LedgerGot(this.id, this.at, this.via, {this.matched = false});
  final String id;
  final int at;
  final String via;
  bool matched;

  List<Object> toJson() => [id, at, via, matched ? 4 : 0];

  static LedgerGot? fromJson(Object? j) {
    if (j is! List || j.length < 4 || j[0] is! String || j[1] is! int || j[2] is! String || j[3] is! int) return null;
    return LedgerGot(j[0] as String, j[1] as int, j[2] as String, matched: (j[3] as int) & 4 != 0);
  }
}

/// Something a friend's device said it sent that never came here, as it was put down: not the relay's doing (`made`:
/// another of the account's devices took it, it couldn't be opened here, another route took it), lost when the relay
/// started again (`restart`), or what the relay got wrong by that device's word (a [LedgerWrongKind]'s name); with the
/// relay it concerns, and whether it then came straight ([came]). Each is put down once. Only one that came is counted
/// (the review, D5 and D7): a friend's device can say anything of what it sent, and only what is then sent straight
/// shows it was so; a wrong is the relay's only then, and "came straight" is said only of what did.
class LedgerMissing {
  LedgerMissing(this.id, this.at, this.kind, {this.relay = '', this.came = false});
  final String id;
  final int at;
  final String kind;
  final String relay;
  bool came;

  List<Object> toJson() => [id, at, kind, relay, came ? 1 : 0];

  static LedgerMissing? fromJson(Object? j) {
    if (j is! List || j.length < 3 || j[0] is! String || j[1] is! int || j[2] is! String) return null;
    return LedgerMissing(j[0] as String, j[1] as int, j[2] as String, relay: j.length > 3 && j[3] is String ? j[3] as String : '', came: j.length > 4 && j[4] == 1);
  }
}

/// A connection this device had to a relay: its address, when it signed in, when anything last came on it, and when
/// the relay said it had started (ms, this device's clock; 0 where it didn't say). It was alive from [signedIn] to at
/// least [heard]: nothing later is claimed for it.
@immutable
class RelaySession {
  const RelaySession(this.url, this.signedIn, this.heard, {this.started = 0});
  final String url;
  final int signedIn;
  final int heard;
  final int started;

  List<Object> toJson() => [url, signedIn, heard, if (started > 0) started];

  static RelaySession? fromJson(Object? j) {
    if (j is! List || j.length < 3 || j[0] is! String || j[1] is! int || j[2] is! int) return null;
    return RelaySession(j[0] as String, j[1] as int, j[2] as int, started: j.length > 3 && j[3] is int ? j[3] as int : 0);
  }
}

/// What the comparisons found of one relay: each comparison (when, with which friend's device), how many messages
/// matched and how many were made up for each day, and each thing it got wrong.
class RelayRecord {
  RelayRecord(this.url);
  final String url;

  /// Each comparison: when, with whom, and a short name of the device (its node id's first 16 hex digits).
  final List<({int at, String friend, String device})> checks = [];

  /// For each day (yyyy-mm-dd, UTC): messages matched; that came straight after the relay didn't bring them; and of
  /// those, lost when the relay started again.
  final Map<String, List<int>> days = {};
  final List<LedgerWrong> wrong = [];

  /// When it was last checked; 0 never.
  int get lastChecked => checks.isEmpty ? 0 : checks.last.at;

  /// How many friends' devices it was checked with in the day before it was last checked.
  int get devices {
    final last = lastChecked;
    return {for (final c in checks) if (last - c.at <= const Duration(days: 1).inMilliseconds) c.device}.length;
  }

  /// Messages matched; that came straight after the relay didn't bring them; and of those, lost when the relay started
  /// again; in the [within] days before [now].
  int matched(int now, {int within = 7}) => _sum(now, within, 0);
  int madeUp(int now, {int within = 7}) => _sum(now, within, 1);
  int restarts(int now, {int within = 7}) => _sum(now, within, 2);

  /// The count at place [at] of each day's list, summed over the [n] days up to [now].
  int _sum(int now, int n, int at) {
    final from = Ledger.dayOf(now - Duration(days: n - 1).inMilliseconds);
    return days.entries.where((e) => e.key.compareTo(from) >= 0).fold(0, (s, e) => s + (e.value.length > at ? e.value[at] : 0));
  }

  Map<String, Object> toJson() => {
        'c': [for (final c in checks) [c.at, c.friend, c.device]],
        'd': days,
        'w': [for (final w in wrong) w.toJson()],
      };

  static RelayRecord fromJson(String url, Object? j) {
    final r = RelayRecord(url);
    if (j is! Map) return r;
    for (final c in (j['c'] is List ? j['c'] as List : const [])) {
      if (c is List && c.length >= 3 && c[0] is int && c[1] is String && c[2] is String) r.checks.add((at: c[0] as int, friend: c[1] as String, device: c[2] as String));
    }
    final d = j['d'];
    if (d is Map) {
      for (final e in d.entries) {
        final v = e.value;
        if (e.key is String && v is List && v.length >= 2 && v.every((x) => x is int)) r.days[e.key as String] = [v[0] as int, v[1] as int, v.length > 2 ? v[2] as int : 0];
      }
    }
    for (final w in (j['w'] is List ? j['w'] as List : const [])) {
      final x = LedgerWrong.fromJson(w);
      if (x != null) r.wrong.add(x);
    }
    return r;
  }
}

/// What the ledger keeps of one friend.
class _Book {
  /// The newest of what came that was dropped to keep to [Ledger.most]: what they sent before it is not compared.
  int cut = 0;
  final List<LedgerSent> sent = [];
  final List<LedgerGot> got = [];
  final List<LedgerMissing> missing = [];

  /// When packets from them came that could not be opened here.
  final List<int> unopened = [];

  bool get empty => sent.isEmpty && got.isEmpty && missing.isEmpty && unopened.isEmpty;

  Map<String, Object> toJson() => {
        if (cut > 0) 'x': cut,
        's': [for (final x in sent) x.toJson()],
        'g': [for (final x in got) x.toJson()],
        if (missing.isNotEmpty) 'm': [for (final x in missing) x.toJson()],
        if (unopened.isNotEmpty) 'u': unopened,
      };

  static _Book? fromJson(Object? j) {
    if (j is! Map) return null;
    final b = _Book()..cut = j['x'] is int ? j['x'] as int : 0;
    List<Object?> list(String k) => j[k] is List ? j[k] as List : const [];
    b.sent.addAll(list('s').map(LedgerSent.fromJson).whereType<LedgerSent>().take(Ledger.most));
    b.got.addAll(list('g').map(LedgerGot.fromJson).whereType<LedgerGot>().take(Ledger.most));
    b.missing.addAll(list('m').map(LedgerMissing.fromJson).whereType<LedgerMissing>().take(Ledger.most));
    b.unopened.addAll(list('u').whereType<int>().take(Ledger.mostUnopened));
    return b;
  }
}

/// The ledger (docs/OPEN_NETWORK.md, section 3; Matt, 2026-11-22: "p2p as a secondary back up that validates everything
/// our relay says"): for each friend, what was **sent** them (the envelope's name, when, the route, what the route
/// said: passed or kept, whether it was answered) and what was **got** from them (name, when, the route), for
/// [keepFor] and at most [most] of each. The switchboard tells it ([SendLog]); [LedgerCheck] compares it with a
/// friend's device over a direct link.
///
/// Only what asks for an answer is listed ([listed]): not typing, tests, cards or the comparing's own messages, and
/// never a word of any message. Not this account's own devices yet (later), nor anyone who is not a friend.
///
/// Beside the lists: this device's own connections to the relay ([RelaySession]: when each signed in, when anything
/// last came on it, and when the relay said it had started), what came that could not be opened here, what a friend's
/// device said it sent that never came ([LedgerMissing], counted once it comes straight), and what each relay was found
/// to do ([RelayRecord]). Kept in files of its own, out of any backup (lib/net/kept_files.dart: [indexName], [bookName],
/// [relayName]); the device it was kept on is named in it all the same, so what another device kept is never taken for
/// this one's.
class Ledger extends ChangeNotifier implements SendLog {
  Ledger({required FsStore store, required this.me, required this.device, bool Function(String account)? isFriend, DateTime Function()? now, LedgerTimer? timer})
      : _store = store,
        _isFriend = isFriend,
        _now = now ?? DateTime.now,
        _timer = timer ?? Timer.new {
    _madeAt = nowMs;
  }

  /// When this ledger began listing (ms). Where the one before it stopped listening while the app went on ([pause]),
  /// what any friend sent before this is not compared ([load]).
  late final int _madeAt;

  /// When this ledger stopped listening while the app went on (Direct switched off: [pause]); 0 where it has not. Said
  /// in what is kept.
  int _paused = 0;

  /// This account's name, and which of its devices this is (`hub_device`).
  final String me;
  final String device;
  final FsStore _store;
  final bool Function(String account)? _isFriend;
  final DateTime Function() _now;
  final LedgerTimer _timer;

  /// How long what went and came is listed, and the most of each kept for one friend.
  static const keepFor = Duration(days: 7);
  static const most = 500;

  /// The longest envelope name listed: the app makes 16 hex digits; anything longer is not one of its own.
  static const longestId = 32;

  /// The most unopened packets remembered for one friend, connections to the relay, comparisons and wrongs kept for one
  /// relay, and relays kept; and how long a wrong is kept.
  static const mostUnopened = 32, mostSessions = 300, mostChecks = 64, mostWrong = 50, mostRelays = 4;
  static const wrongFor = Duration(days: 30);

  /// How long after a change what is kept is written: a busy chat writes it every so often, not at every message.
  static const saveAfter = Duration(seconds: 20);

  /// The relay's route ([HubCarrier.id]): its word is what is checked.
  static const relayRoute = 'hub';

  /// Where it is kept with the app's choices: which friends have a book and on which device it was kept; each friend's
  /// book; and the relay's connections and records.
  static const indexName = 'ldg', relayName = 'ldg_relay';
  static String bookName(String account) => 'ldg.$account';

  /// Each friend's book, by account.
  final Map<String, _Book> _books = {};

  /// When this device first knew each friend as one (anything from or to them, a card included): what they sent before
  /// is not compared, as it was not listed (it came before they were a friend here).
  final Map<String, int> _since = {};

  /// The connections this device had to relays, and what the comparisons found of each relay, by its address. Then
  /// how the ledger stands (read, signed out of, closed), the wait before the next write, the books and whether the
  /// relay's part changed since the last one, and the friends whose books are written already.
  final List<RelaySession> _sessions = [];
  final Map<String, RelayRecord> _relays = {};
  bool _loaded = false, _wiped = false, _gone = false;
  Timer? _saving;
  final Set<String> _dirty = {};
  bool _relayDirty = false;
  Set<String> _keptBooks = {};

  /// What the ledger writes, one after another: the flush twenty seconds after a change, the flush as the app is put
  /// away, and signing out's wipe, so two never write the same file at once (the second review, N5).
  Future<void> _writing = Future.value();

  /// Runs [write] once whatever is being written is done; one that throws does not stop the next.
  Future<void> _inTurn(Future<void> Function() write) {
    final run = _writing.then((_) => write());
    _writing = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  int get nowMs => _now().millisecondsSinceEpoch;
  bool get loaded => _loaded;

  /// Whether [e] is listed: sealed things that ask for an answer, not a test, with a name the app would make.
  static bool listed(Envelope e) => e.ack && e.kind != 'ping' && e.id.isNotEmpty && e.id.length <= longestId;

  /// The day [ms] falls on, by UTC: yyyy-mm-dd.
  static String dayOf(int ms) => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String().substring(0, 10);

  /// Whether [account] is a friend now.
  bool _friend(String account) {
    if (account == me) return false;
    try {
      return _isFriend?.call(account) ?? true;
    } catch (_) {
      return false;
    }
  }

  /// Whether what went to or came from [account] is listed: a friend's, while the ledger runs. Known as a friend from
  /// now, where not before.
  bool _takes(String account) {
    if (_wiped || _gone) return false;
    final friend = _friend(account);
    if (friend && !_since.containsKey(account)) {
      _since[account] = nowMs;
      _dirty.add(account);
      _saveSoon();
    }
    return friend;
  }

  /// [account]'s book, begun where there is none.
  _Book _book(String account) => _books[account] ??= _Book();

  // --- what the switchboard says ------------------------------------------------------------------------------------

  @override
  void sent(Peer peer, Envelope envelope, {required String via, required Handed handed}) {
    if (!_takes(peer.id) || !listed(envelope)) return;
    final b = _book(peer.id), now = nowMs, kept = handed == Handed.held;
    final i = b.sent.indexWhere((x) => x.id == envelope.id);
    if (i < 0) {
      b.sent.add(LedgerSent(envelope.id, now, via, kept: kept));
    } else {
      // Sent again: the relay's word is what is checked, so another route's never takes the place of the relay's; the
      // relay's latest does.
      final x = b.sent.removeAt(i);
      if (via == relayRoute || x.via != relayRoute) {
        x
          ..at = now
          ..via = via
          ..kept = kept;
      }
      b.sent.add(x);
    }
    _trim(peer.id, b);
  }

  @override
  void came(Peer peer, Envelope envelope, {required String via}) {
    if (!_takes(peer.id) || !listed(envelope)) return;
    final b = _book(peer.id);
    if (b.got.any((x) => x.id == envelope.id)) return;
    b.got.add(LedgerGot(envelope.id, nowMs, via));
    // One put down as missing that came after all, straight: counted now, and where it was the relay's doing by their
    // device's word, put down against it now (it was so).
    final m = b.missing.where((x) => x.id == envelope.id && !x.came).firstOrNull;
    if (m != null) {
      m.came = true;
      _cameStraight(peer.id, m);
    }
    _trim(peer.id, b);
  }

  /// A message put down as missing came after all: counted for its relay's day as made up (and as lost to a restart
  /// where it was), and where what was put down is a wrong, put down against that relay now.
  void _cameStraight(String account, LedgerMissing m) {
    if (m.relay.isEmpty || _wiped || _gone) return;
    final r = _relays[m.relay] ??= RelayRecord(m.relay);
    final now = nowMs;
    final counts = r.days[dayOf(now)] ??= [0, 0, 0];
    while (counts.length < 3) {
      counts.add(0);
    }
    counts[1]++;
    if (m.kind == 'restart') counts[2]++;
    final kind = LedgerWrongKind.values.asNameMap()[m.kind];
    if (kind != null) {
      r.wrong.add(LedgerWrong(kind, now, account));
      while (r.wrong.length > mostWrong) {
        r.wrong.removeAt(0);
      }
    }
    _relayDirty = true;
    _saveSoon();
  }

  @override
  void answered(Peer peer, String id) {
    final x = _books[peer.id]?.sent.where((x) => x.id == id).firstOrNull;
    if (x == null || x.answered) return;
    x.answered = true;
    _changed(peer.id);
  }

  @override
  void unopened(Peer peer, {required String via}) {
    if (!_takes(peer.id)) return;
    final b = _book(peer.id);
    b.unopened.add(nowMs);
    _trim(peer.id, b);
  }

  /// Keeps [b] to [keepFor] and [most]; written soon.
  void _trim(String account, _Book b) {
    final old = nowMs - keepFor.inMilliseconds;
    b.sent.removeWhere((x) => x.at < old);
    b.got.removeWhere((x) => x.at < old);
    b.missing.removeWhere((x) => x.at < old);
    b.unopened.removeWhere((t) => t < old);
    while (b.sent.length > most) {
      b.sent.removeAt(0);
    }
    while (b.got.length > most) {
      final x = b.got.removeAt(0);
      if (x.at > b.cut) b.cut = x.at;
    }
    while (b.missing.length > most) {
      b.missing.removeAt(0);
    }
    while (b.unopened.length > mostUnopened) {
      b.unopened.removeAt(0);
    }
    _changed(account);
  }

  /// [account]'s book changed: it is written soon, and whoever listens is told.
  void _changed(String account) {
    _dirty.add(account);
    _saveSoon();
    if (!_gone) notifyListeners();
  }

  // --- what the comparing asks -------------------------------------------------------------------------------------

  /// The friends a book is kept for.
  Iterable<String> get friends => _books.keys;

  /// What is listed as sent to [account], and as got from them, oldest first.
  List<LedgerSent> sentTo(String account) => List.unmodifiable(_books[account]?.sent ?? const <LedgerSent>[]);
  List<LedgerGot> gotFrom(String account) => List.unmodifiable(_books[account]?.got ?? const <LedgerGot>[]);
  List<LedgerMissing> missingFrom(String account) => List.unmodifiable(_books[account]?.missing ?? const <LedgerMissing>[]);

  /// The time (ms, this device's clock) from which everything [account] sent is listed here: later than when this
  /// device first knew them as a friend, than [keepFor] ago, and than anything dropped to keep to [most]. Null where
  /// they are not known here as a friend.
  int? horizon(String account) {
    final since = _since[account];
    if (since == null) return null;
    final old = nowMs - keepFor.inMilliseconds;
    return [since, old, (_books[account]?.cut ?? 0) + 1].reduce((a, c) => a > c ? a : c);
  }

  /// When a packet from [account] that could not be opened here came within [within] of [at].
  bool unopenedNear(String account, int at, Duration within) => (_books[account]?.unopened ?? const <int>[]).any((t) => (t - at).abs() <= within.inMilliseconds);

  /// What [account]'s device is told of this one's lists, for a comparison: the window they cover (from, now), what was
  /// sent (name, when, and what the relay said: `p` passed, `k` kept, `o` another route took it) and the names of what
  /// came.
  Map<String, dynamic> summary(String account) {
    final b = _books[account];
    final now = nowMs;
    return {
      'w': [horizon(account) ?? now, now],
      's': [for (final x in b?.sent ?? const <LedgerSent>[]) [x.id, x.at, x.via != relayRoute ? 'o' : x.kept ? 'k' : 'p']],
      'g': [for (final x in b?.got ?? const <LedgerGot>[]) x.id],
    };
  }

  /// Marks what came from [account] as [id] as matched by their device's word; whether it was not before.
  bool matchGot(String account, String id) {
    final x = _books[account]?.got.where((x) => x.id == id).firstOrNull;
    if (x == null || x.matched) return false;
    x.matched = true;
    _changed(account);
    return true;
  }

  /// Marks what went to [account] as [id] as matched, and answered: their device says it came. Whether it was not
  /// matched before, and whether it was not answered before.
  ({bool matched, bool answered}) matchSent(String account, String id) {
    final x = _books[account]?.sent.where((x) => x.id == id).firstOrNull;
    if (x == null) return (matched: false, answered: false);
    final m = !x.matched, a = !x.answered;
    x
      ..matched = true
      ..answered = true;
    if (m || a) _changed(account);
    return (matched: m, answered: a);
  }

  /// Whether [id] from [account] was put down as missing before.
  bool wasMissing(String account, String id) => _books[account]?.missing.any((x) => x.id == id) ?? false;

  /// Puts down [id] from [account] as missing, of [relay]: `made`, `restart`, or what the relay got wrong by their
  /// device's word. Counted only once it comes ([came]).
  void putMissing(String account, String id, String kind, {String relay = ''}) {
    final b = _book(account);
    if (b.missing.any((x) => x.id == id)) return;
    b.missing.add(LedgerMissing(id, nowMs, kind, relay: relay));
    _trim(account, b);
  }

  // --- this device's connections to the relay -------------------------------------------------------------------------

  /// The connection to [url] that signed in at [signedIn] has heard something as late as [heard], and the relay said at
  /// that sign-in it had started at [started] (0: it didn't say): kept, or brought up to then.
  void relay(String url, int signedIn, int heard, {int started = 0}) {
    if (signedIn <= 0 || _wiped || _gone) return;
    final i = _sessions.lastIndexWhere((s) => s.url == url && s.signedIn == signedIn);
    if (i >= 0) {
      if (_sessions[i].heard >= heard) return;
      _sessions[i] = RelaySession(url, signedIn, heard, started: _sessions[i].started > 0 ? _sessions[i].started : started);
    } else {
      _sessions.add(RelaySession(url, signedIn, heard < signedIn ? signedIn : heard, started: started));
    }
    final old = nowMs - keepFor.inMilliseconds;
    _sessions.removeWhere((s) => s.heard < old);
    while (_sessions.length > mostSessions) {
      _sessions.removeAt(0);
    }
    _relayDirty = true;
    _saveSoon();
  }

  /// The connections kept, oldest first.
  List<RelaySession> get sessions => List.unmodifiable(_sessions);

  /// Whether this device was connected to [url] at [at], with proof: signed in [slack] before, and something came on
  /// the same connection [slack] after (frames come in order, so what the relay put on it at [at] came before that).
  bool connectedAt(String url, int at, {required Duration slack}) => _sessions.any((s) => s.url == url && s.signedIn <= at - slack.inMilliseconds && s.heard >= at + slack.inMilliseconds);

  /// Whether the relay at [url] started again after [at]: the first time this device signed in to it after [at], it
  /// said it had started since (the review, D2). What it kept before then went with the restart.
  bool restartedAfter(String url, int at, {required Duration slack}) {
    final after = _sessions.where((s) => s.url == url && s.signedIn >= at + slack.inMilliseconds).toList()..sort((a, b) => a.signedIn.compareTo(b.signedIn));
    final first = after.firstOrNull;
    return first != null && first.started > at + slack.inMilliseconds;
  }

  // --- what was found of each relay ----------------------------------------------------------------------------------------

  /// What the comparisons found, by relay; the relay in use is first where the caller sorts it so.
  Map<String, RelayRecord> get relays => Map.unmodifiable(_relays);

  /// A comparison with [friend]'s device ([device], its node id) found [matched] messages matched and [madeUp] made up
  /// for, and [wrong] wrongs, of the relay at [url].
  void checked(String url, String friend, String device, {int matched = 0, int madeUp = 0, List<LedgerWrong> wrong = const []}) {
    if (_wiped || _gone) return;
    final r = _relays[url] ??= RelayRecord(url);
    final now = nowMs;
    r.checks.add((at: now, friend: friend, device: device.length > 16 ? device.substring(0, 16) : device));
    r.checks.removeWhere((c) => now - c.at > keepFor.inMilliseconds);
    while (r.checks.length > mostChecks) {
      r.checks.removeAt(0);
    }
    final day = dayOf(now);
    final counts = r.days[day] ??= [0, 0, 0];
    counts[0] += matched;
    counts[1] += madeUp;
    final oldest = dayOf(now - const Duration(days: 8).inMilliseconds);
    r.days.removeWhere((d, _) => d.compareTo(oldest) < 0);
    r.wrong.addAll(wrong);
    r.wrong.removeWhere((w) => now - w.at > wrongFor.inMilliseconds);
    while (r.wrong.length > mostWrong) {
      r.wrong.removeAt(0);
    }
    // The newest relays only: one moved away from long ago is let go.
    while (_relays.length > mostRelays) {
      _relays.remove(_relays.values.reduce((a, b) => a.lastChecked <= b.lastChecked ? a : b).url);
    }
    _relayDirty = true;
    _saveSoon();
    if (!_gone) notifyListeners();
  }

  /// When [friend] was last compared with, at any relay (ms; 0 never).
  int comparedWith(String friend) {
    var last = 0;
    for (final r in _relays.values) {
      for (final c in r.checks) {
        if (c.friend == friend && c.at > last) last = c.at;
      }
    }
    return last;
  }

  // --- keeping -------------------------------------------------------------------------------------------------------------

  /// Reads what is kept. What was listed meanwhile stays, and what is kept is put before it. Nothing kept on another
  /// device is taken. Asked again while it reads, it is the same reading.
  Future<void> load() => _loading ??= _load().whenComplete(() => _loading = null);
  Future<void>? _loading;

  Future<void> _load() async {
    if (_loaded || _wiped || _gone) return;
    Map? index;
    try {
      index = jsonDecode(await _store.read(indexName) ?? '') as Map;
    } catch (_) {}
    final mine = index != null && index['d'] == device;
    final keptBooks = <String>{};
    var raise = false;
    if (mine) {
      final since = index['k'];
      if (since is Map) {
        for (final e in since.entries) {
          final at = e.value, had = _since[e.key];
          if (e.key is String && at is int && (had == null || at < had)) _since[e.key as String] = at;
        }
      }
      // The ledger before this one stopped listening while the app went on (Direct was switched off), so what came
      // since was listed nowhere: from each friend, only what came after this one began is compared. What was listed
      // stays, and still answers their device's questions.
      final paused = index['p'];
      if (paused is int && paused > 0) {
        raise = true;
        for (final account in _since.keys.toList()) {
          if (_since[account]! < _madeAt) _since[account] = _madeAt;
        }
      }
      for (final account in (index['f'] is List ? index['f'] as List : const []).whereType<String>()) {
        keptBooks.add(account);
        _Book? kept;
        try {
          kept = _Book.fromJson(jsonDecode(await _store.read(bookName(account)) ?? ''));
        } catch (_) {}
        if (kept == null || _wiped || _gone) continue;
        final now = _books[account];
        if (now != null) {
          for (final x in now.sent) {
            kept.sent
              ..removeWhere((o) => o.id == x.id)
              ..add(x);
          }
          for (final x in now.got) {
            if (!kept.got.any((o) => o.id == x.id)) kept.got.add(x);
          }
          kept.missing.addAll(now.missing);
          kept.unopened.addAll(now.unopened);
        }
        _books[account] = kept;
      }
      try {
        final r = jsonDecode(await _store.read(relayName) ?? '') as Map;
        final kept = [for (final s in (r['s'] is List ? r['s'] as List : const [])) ?RelaySession.fromJson(s)];
        _sessions.insertAll(0, kept.where((k) => !_sessions.any((s) => s.url == k.url && s.signedIn == k.signedIn)));
        final rel = r['r'];
        if (rel is Map) {
          for (final e in rel.entries) {
            if (e.key is String && !_relays.containsKey(e.key)) _relays[e.key as String] = RelayRecord.fromJson(e.key as String, e.value);
          }
        }
      } catch (_) {}
    } else if (index != null) {
      // Kept on another device (its choices restored here): none of it is this device's. Written over at the next save.
      for (final account in (index['f'] is List ? index['f'] as List : const []).whereType<String>()) {
        keptBooks.add(account);
      }
      _relayDirty = true;
    }
    if (_wiped || _gone) return;
    _keptBooks = keptBooks;
    _loaded = true;
    for (final account in _books.keys.toList()) {
      _trim(account, _books[account]!);
    }
    // (What is kept is written again without the mark, with each friend's horizon where it now is.)
    if ((!mine && index != null) || raise) _saveSoon();
    if (!_gone) notifyListeners();
  }

  /// Writes what changed [saveAfter] from now, unless a write waits already.
  void _saveSoon() {
    if (!_loaded || _saving != null || _wiped || _gone) return;
    _saving = _timer(saveAfter, () {
      _saving = null;
      unawaited(flush());
    });
  }

  /// Writes what changed now: each friend's book first, then the relay's connections (so a connection is never kept as
  /// having heard later than the lists kept beside it). After any flush or wipe still writing ([_inTurn]).
  Future<void> flush() {
    _saving?.cancel();
    _saving = null;
    return _inTurn(_flush);
  }

  Future<void> _flush() async {
    if (!_loaded || _wiped) return;
    // A friend no longer one: nothing of them is kept.
    for (final account in _books.keys.toList()) {
      final b = _books[account]!;
      if (b.empty || !_friend(account)) {
        _books.remove(account);
        _dirty.add(account);
      }
    }
    _since.removeWhere((account, _) => !_friend(account));
    final dirty = Set.of(_dirty);
    _dirty.clear();
    final books = {..._books.keys};
    try {
      for (final account in dirty) {
        final b = _books[account];
        if (b == null && !_keptBooks.contains(account)) continue;
        await _store.write(bookName(account), b == null ? '' : jsonEncode(b.toJson()));
      }
      for (final gone in _keptBooks.difference(books)) {
        if (!dirty.contains(gone)) await _store.write(bookName(gone), '');
      }
      if (_wiped) return;
      await _store.write(indexName, jsonEncode({'d': device, 'f': books.toList(), 'k': _since, if (_paused > 0) 'p': _paused}));
      _keptBooks = books;
      if (_relayDirty) {
        _relayDirty = false;
        await _store.write(relayName, jsonEncode({'s': [for (final s in _sessions) s.toJson()], 'r': {for (final e in _relays.entries) e.key: e.value.toJson()}}));
      }
      if (_wiped) await forget(_store);
    } catch (_) {
      _dirty.addAll(dirty);
    }
  }

  /// Signing out: nothing of the ledger is kept, here or with the choices. Once a flush still writing has ended, every
  /// book it may have written goes, those it had not yet listed too.
  Future<void> wipe() async {
    _wiped = true;
    _saving?.cancel();
    _saving = null;
    final books = {for (final account in {..._books.keys, ..._keptBooks, ..._dirty}) bookName(account)};
    _books.clear();
    _since.clear();
    _sessions.clear();
    _relays.clear();
    _dirty.clear();
    await _inTurn(() async {
      for (final name in books) {
        if ((await _store.read(name) ?? '').isNotEmpty) await _store.write(name, '');
      }
      await forget(_store);
    });
    if (!_gone) notifyListeners();
  }

  /// Deletes what a ledger keeps in [store], where none is running to [wipe] itself.
  static Future<void> forget(FsStore store) async {
    for (final name in keptIn(await store.read(indexName) ?? '')) {
      if ((await store.read(name) ?? '').isNotEmpty) await store.write(name, '');
    }
  }

  /// The names a ledger keeps under, read from what is kept as its index ([indexName]): the index, each friend's book
  /// and the relay's record. Only those that may be there; signing out writes them empty where they are not.
  static List<String> keptIn(String index) {
    List<Object?> friends = const [];
    try {
      final j = jsonDecode(index);
      if (j is Map && j['f'] is List) friends = j['f'] as List;
    } catch (_) {}
    return [for (final account in friends.whereType<String>()) bookName(account), indexName, relayName];
  }

  /// Direct was switched off, and the ledger goes with the direct route (lib/net/net.dart) while the app goes on:
  /// what comes from now until a ledger is made again is listed nowhere. Said at once in what is kept, so that the next
  /// ledger to [load] it compares only what came after it began, and never takes what came meanwhile, unlisted, for
  /// something the relay dropped. What was listed stays, and so does what was found of each relay.
  Future<void> pause() async {
    // (Switched off while what is kept was still being read: once it has been, or the mark would be written over.)
    try {
      await load();
    } catch (_) {}
    if (!_loaded || _wiped || _gone) return;
    _paused = nowMs;
    await flush();
  }

  /// The app is closing: what changed is written, and nothing more is listed.
  Future<void> shutdown() async {
    await flush();
    _gone = true;
    _saving?.cancel();
    _saving = null;
  }
}

/// Comparing over a direct link (docs/OPEN_NETWORK.md, section 3): when a direct stream to a friend's device has been
/// proved, and every [every] while it stays open, the two devices tell each other their lists of what went between
/// them, sealed, in envelopes of kind [kind] that go **only by the direct route**, on that stream, and never ask to
/// be answered:
///
///     {"t":"sum", "w":[from, now], "s":[[name, when, "p"|"k"|"o"], …], "g":[name, …],
///      "h":{"u": my relay, "up": whether I'm connected to it, "t": since when, "heard": when it last heard from it}}
///     {"t":"dif", "want":[name, …]}            I never got these: send them straight
///
/// (`up` is left out while the person chose Invisible: the relay hides them from friends then, on purpose.)
///
/// `s` is what was sent to the other account in the window, with when and what the relay said of each as it took it
/// (`p` passed on, `k` kept for them; `o` another route took it), `g` the names of what came from them. Section 3's
/// `was` is folded into `s`: each name's time is needed anyway, to compare only what both lists cover and to leave out
/// what may still be on its way, and what the relay said comes with it, so nothing waits on a second round.
///
/// What the other device's `sum` says is weighed here:
///
/// - What they sent that never came here is asked for (`dif`), and sent again straight by whoever still holds it
///   (the switchboard's unanswered, Friends' own list of what is unanswered: [holders]; a call that has stopped ringing
///   is not), on the stream that asked.
/// - What came there and was never answered here is taken as answered ([Switchboard.answeredBy]): the answer was lost.
/// - Each thing that never came here is put down once as one of: nobody's doing (this device was away and another of
///   the account's took it, it could not be opened here, another route took it, or the relay kept it and may have
///   handed it to another of the account's devices: the relay hands what it kept to whichever signs in first, and
///   nothing here can prove none did, so "kept it and never handed it over" is not put down for now), **lost when the
///   relay started again** (it kept it, and said at the next sign-in that it had started since), **the relay said it
///   passed it on and it never came** (this device was connected to it then, by the proof [Ledger.connectedAt] asks),
///   or **the relay said this device was away** while it was connected. Each is counted, and a wrong put down against
///   the relay, only once the message then comes straight (Ledger.came): a friend's device can say anything of what it
///   sent, and what it then sends shows it was so. What is put down is that device's word, and said as such.
/// - A friend whose device says, in two sums in a row, that it is connected to the same relay and heard from it just
///   now, while the relay says they are gone, is put down as the relay being wrong about who is here.
///
/// **Bounded.** A `sum` of more than [Ledger.most] names in either list, a name longer than [Ledger.longestId], or a
/// `dif` of more than [mostWant], is refused whole. No more than one `sum` from a device is weighed every [sumEvery],
/// nor more than [sumsAnHour] from one account; no more than [difsAnHour] `dif`s and [sentAgainAnHour] things sent
/// again for one account. What it puts down is the ledger's, capped there.
///
/// **Checking.** [checkNow] dials the friends the relay says are here, once a minute at most; with no direct link in
/// use a round runs by itself while the app is on screen ([roundsComputer], [roundsPhone]): up to [roundMost] friends
/// not compared in a day.
class LedgerCheck extends ChangeNotifier {
  LedgerCheck({required this.ledger, required this.board, required this.p2p, required HubCarrier? Function() relay, DateTime Function()? now, LedgerTimer? timer})
      : _relay = relay,
        _now = now ?? DateTime.now,
        _timer = timer ?? Timer.new;

  /// The ledger written in, the routes and the direct network compared over, and the relay's route as it is now (null
  /// while there is none).
  final Ledger ledger;
  final Switchboard board;
  final P2p p2p;
  final HubCarrier? Function() _relay;
  final DateTime Function() _now;
  final LedgerTimer _timer;

  /// What the comparing's envelopes are.
  static const kind = 'ldg';

  /// How often a link that stays open is compared again.
  static const every = Duration(minutes: 15);

  /// What was sent less than this before the other device's `sum` was made may still be on its way: not compared.
  static const settle = Duration(minutes: 2);

  /// How much each side of a moment is allowed for this device's clock and the other's, and for what is on its way: a
  /// connection is held to have been up at a moment only where it signed in this long before and heard something this
  /// long after.
  static const slack = Duration(seconds: 10);

  /// An unopened packet this near a message's time is taken for that message.
  static const unopenedNear = Duration(seconds: 30);

  /// How long a friend's device must have said it is connected, and this one been connected, before the relay saying
  /// they are gone counts against it; how lately their device must have heard from the relay as it said so; and how
  /// often that is put down for one friend (two of their sums in a row must say so).
  static const goneAfter = Duration(minutes: 1), heardWithin = Duration(minutes: 2), goneEvery = Duration(hours: 6);

  /// A device's clock this far from this one's is not compared with: the times would mean nothing.
  static const mostSkew = Duration(days: 1);

  /// The limits on what a friend's device can make this one do.
  static const mostWant = 64, sumsAnHour = 12, difsAnHour = 6, sentAgainAnHour = 200;
  static const sumEvery = Duration(minutes: 10);

  /// "Check now" at most this often; and the rounds that run by themselves.
  static const checkNowEvery = Duration(minutes: 1);
  static const roundsComputer = Duration(hours: 1), roundsPhone = Duration(hours: 6);
  static const roundMost = 5, checkNowMost = 12;
  static const roundAfter = Duration(days: 1);

  /// Extra holders of what was sent and is unanswered, beside the switchboard's own ([Switchboard.held]): Friends' list.
  final List<Envelope? Function(String peer, String id)> holders = [];

  /// How many `ldg` messages were refused for being too big or too many.
  int refused = 0;

  /// The friends' devices linked now ("account nodeId"), and the wait before each is compared with again.
  Set<String> _links = {};
  final Map<String, Timer> _again = {};

  /// When a `sum` was last sent to, and weighed from, each device (by node id); and for each account, when its sums and
  /// difs were weighed and things were sent it again, within the hour ([_mayHave]).
  final Map<String, int> _sumSent = {}, _sumHeard = {};
  final Map<String, List<int>> _sums = {}, _difs = {}, _sentAgain = {};
  final Map<String, int> _goneSaid = {}, _goneRun = {};
  int _checkedNow = 0;
  Timer? _round;
  StreamSubscription<Received>? _heard;
  HubCarrier? _hub;
  bool _started = false;

  int get nowMs => _now().millisecondsSinceEpoch;

  /// Whether "Check now" may be pressed now.
  bool get canCheckNow => _started && p2p.on && nowMs - _checkedNow >= checkNowEvery.inMilliseconds;

  /// When "Check now" was last pressed (ms; 0 never).
  int get checkedNow => _checkedNow;

  /// Begins hearing what comes, the direct links and the routes, and sets the first round that runs by itself.
  void start() {
    if (_started) return;
    _started = true;
    _heard = board.received.listen(_received);
    p2p.addListener(_linksChanged);
    board.changed.addListener(_routesChanged);
    _routesChanged();
    _linksChanged();
    _roundSoon();
  }

  /// Stops hearing all of it, and drops every wait.
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    await _heard?.cancel();
    _heard = null;
    p2p.removeListener(_linksChanged);
    board.changed.removeListener(_routesChanged);
    _follow(null);
    for (final t in _again.values) {
      t.cancel();
    }
    _again.clear();
    _round?.cancel();
    _round = null;
  }

  // --- this device's connection to the relay ---------------------------------------------------------------------------

  /// The routes changed: the relay's route may be another one now.
  void _routesChanged() => _follow(_relay());

  /// Listens to [hub]'s state in place of the one listened to before.
  void _follow(HubCarrier? hub) {
    if (identical(hub, _hub)) return;
    _hub?.state.removeListener(_relayState);
    _hub = hub;
    hub?.state.addListener(_relayState);
    _relayState();
  }

  /// The relay's connection came or went: what it heard is put down in the ledger.
  void _relayState() => _noteRelay();

  /// Puts this device's connection to the relay in the ledger, once it has signed in: the relay's address, when it
  /// signed in, when it last heard anything, and when the relay said it started.
  void _noteRelay() {
    final hub = _hub;
    if (hub != null && hub.signedInAt > 0) ledger.relay(hub.url, hub.signedInAt, hub.heardAt, started: hub.relayStartedAt);
  }

  // --- links -----------------------------------------------------------------------------------------------------------------

  /// The direct network changed: each friend's device newly linked is compared with, and the wait of each no longer
  /// linked is dropped. This account's own devices are not compared with.
  void _linksChanged() {
    if (!_started) return;
    final now = <String>{};
    try {
      for (final l in p2p.carrier.links) {
        if (l.account != p2p.me) now.add('${l.account} ${l.nodeId}');
      }
    } catch (_) {}
    for (final fresh in now.difference(_links)) {
      final i = fresh.indexOf(' ');
      _compare(fresh.substring(0, i), fresh.substring(i + 1));
    }
    for (final gone in _links.difference(now)) {
      _again.remove(gone)?.cancel();
    }
    _links = now;
  }

  /// Sends [account]'s device at [nodeId] this device's `sum`, by the stream proved to it, at most every [sumEvery]; and
  /// looks again every [every] while that stream stays open.
  void _compare(String account, String nodeId) {
    final key = '$account $nodeId';
    _again.remove(key)?.cancel();
    if (_started) {
      _again[key] = _timer(every, () {
        _again.remove(key);
        if (_links.contains(key)) _compare(account, nodeId);
      });
    }
    final now = nowMs;
    _sumSent.removeWhere((_, t) => now - t >= const Duration(hours: 1).inMilliseconds);
    if (now - (_sumSent[nodeId] ?? -sumEvery.inMilliseconds) < sumEvery.inMilliseconds) return;
    final line = p2p.carrier.lineTo(account, nodeId);
    final peer = board.peers.byId(account);
    if (line == null || peer == null || peer.key == null || !p2p.mayLink(account)) return;
    _sumSent[nodeId] = now;
    _noteRelay();
    final hub = _hub;
    final body = {
      't': 'sum',
      ...ledger.summary(account),
      // Whether this device is connected to the relay, since when, and when it last heard anything on that connection
      // (a connection that died unsaid says nothing for long: the review, D4). Nothing of it while the person chose
      // Invisible: the relay hides them from their friends then, on purpose, and that is no fault of its (D1).
      if (hub != null) 'h': {'u': hub.url, if (hub.mode != 'invisible') 'up': hub.state.value == CarrierState.up, 't': hub.signedInAt, 'heard': hub.heardAt},
    };
    _quietly(board.sendOn(peer, Envelope(kind: kind, body: body, ack: false), via: p2p.carrier.id, line: line));
  }

  /// Runs [work] without waiting for it; what goes wrong in it stays in it.
  static void _quietly(Future<Object?> work) => unawaited(work.then((_) {}, onError: (Object _) {}));

  // --- what comes ---------------------------------------------------------------------------------------------------------

  /// What a route brought. An `ldg` envelope is weighed only where it came sealed, by the direct route, on a stream
  /// proved to be a friend's device's: a `sum` or a `dif`.
  void _received(Received r) {
    // Something came: what this device's connection to the relay last heard is kept up to date, so what is kept of it
    // after the app starts again is no older than the last thing that came.
    _noteRelay();
    final e = r.envelope;
    if (e.kind != kind) return;
    // By the direct route only, sealed, from a friend's device on a stream proved to be theirs: never through the
    // relay, whose word this is checking.
    if (!r.sealed || r.via != p2p.carrier.id) return;
    final account = r.peer.id;
    if (account == p2p.me || !p2p.mayLink(account)) return;
    final nodeId = p2p.carrier.nodeOf(r.arrived?.line);
    if (nodeId == null) return;
    switch (e.body['t']) {
      case 'sum':
        _sum(r, account, nodeId, e.body);
      case 'dif':
        _dif(r, account, e.body);
    }
  }

  /// Whether one more may be had in an hour of [list] (times), counted where it may.
  bool _mayHave(Map<String, List<int>> lists, String account, int most) {
    final now = nowMs;
    final list = lists[account] ??= [];
    list.removeWhere((t) => now - t >= const Duration(hours: 1).inMilliseconds);
    if (list.length >= most) return false;
    list.add(now);
    return true;
  }

  /// Whether [x] could be an envelope's name: a string, not empty, no longer than [Ledger.longestId].
  static bool _id(Object? x) => x is String && x.isNotEmpty && x.length <= Ledger.longestId;

  /// Weighs a `sum` from [account]'s device at [nodeId]: what it says it sent is held against what came here (matched,
  /// or put down as missing and asked for), what it says came there against what was sent, and what it says of its
  /// connection to the relay against whom the relay says is here.
  void _sum(Received r, String account, String nodeId, Map<String, dynamic> body) {
    final w = body['w'], s = body['s'], g = body['g'], h = body['h'];
    // Refused whole: anything that is not what a sum is, or bigger than a ledger keeps.
    if (w is! List || w.length != 2 || w[0] is! int || w[1] is! int || s is! List || g is! List || s.length > Ledger.most || g.length > Ledger.most) {
      refused++;
      return;
    }
    final sent = <({String id, int at, String said})>[];
    for (final x in s) {
      if (x is! List || x.length != 3 || !_id(x[0]) || x[1] is! int || (x[2] != 'p' && x[2] != 'k' && x[2] != 'o')) {
        refused++;
        return;
      }
      sent.add((id: x[0] as String, at: x[1] as int, said: x[2] as String));
    }
    if (!g.every(_id) || (h != null && h is! Map)) {
      refused++;
      return;
    }
    // Too often: from that device, or from that account's devices together.
    final now = nowMs;
    _sumHeard.removeWhere((_, t) => now - t >= const Duration(hours: 1).inMilliseconds);
    if (now - (_sumHeard[nodeId] ?? -sumEvery.inMilliseconds) < sumEvery.inMilliseconds || !_mayHave(_sums, account, sumsAnHour)) {
      refused++;
      return;
    }
    _sumHeard[nodeId] = now;
    final theirNow = w[1] as int;
    final skew = now - theirNow;
    if (skew.abs() > mostSkew.inMilliseconds) return;
    final hub = _hub;
    final relay = hub?.url;
    final theirRelay = h is Map && h['u'] is String ? h['u'] as String : null;
    final same = relay != null && theirRelay != null && _sameRelay(relay, theirRelay);
    _noteRelay();
    final horizon = ledger.horizon(account);
    final got = {for (final x in ledger.gotFrom(account)) x.id};
    var matched = 0;
    final wrong = <LedgerWrong>[], want = <String>[];
    for (final x in sent) {
      // Still on its way, or from before this device's list of them begins.
      if (x.at > theirNow - settle.inMilliseconds) continue;
      final at = x.at + skew;
      if (horizon == null || at < horizon || ledger.wasMissing(account, x.id)) continue;
      if (got.contains(x.id)) {
        if (ledger.matchGot(account, x.id)) matched++;
        continue;
      }
      // Never came here: put down for what it was, and counted only once it comes straight (Ledger.came): their
      // device's word alone shows nothing (the review, D5).
      ledger.putMissing(account, x.id, _kindOf(account, at, x.said, same: same, relay: relay), relay: relay ?? '');
      want.add(x.id);
    }
    // What came there: matched, and answered where the answer never came here.
    for (final id in g.cast<String>()) {
      final m = ledger.matchSent(account, id);
      if (m.matched) matched++;
      if (m.answered) board.answeredBy(account, id);
    }
    // They say they are connected to this same relay and heard from it just now, and it says they are gone: put down
    // only where two of their sums in a row say so (the review, D4), and once in [goneEvery].
    var gone = false;
    if (same && h is Map && h['up'] == true && h['t'] is int && h['heard'] is int && hub != null && hub.state.value == CarrierState.up && hub.watching(account) && !hub.here.value.contains(account)) {
      final since = (h['t'] as int) + skew, heard = h['heard'] as int;
      gone = since > 0 && now - since >= goneAfter.inMilliseconds && theirNow - heard <= heardWithin.inMilliseconds && heard <= theirNow && now - hub.signedInAt >= goneAfter.inMilliseconds;
    }
    final run = _goneRun[account] = gone ? (_goneRun[account] ?? 0) + 1 : 0;
    if (run >= 2 && now - (_goneSaid[account] ?? 0) >= goneEvery.inMilliseconds) {
      _goneSaid[account] = now;
      _goneRun[account] = 0;
      wrong.add(LedgerWrong(LedgerWrongKind.gone, now, account));
    }
    if (relay != null) ledger.checked(relay, account, nodeId, matched: matched, wrong: wrong);
    if (!_started) return;
    notifyListeners();
    final peer = r.peer;
    if (want.isNotEmpty) {
      _quietly(board.send(peer, Envelope(kind: kind, body: {'t': 'dif', 'want': want.take(mostWant).toList()}, ack: false), answering: r.arrived));
    }
    // And this device's own, where it has not said it lately: the other compares too.
    _compare(account, nodeId);
  }

  /// What became of a message [account] sent at [at] (this device's clock), which the relay said [said] of and which
  /// never came here: `made` where it was nobody's fault, `restart` where the relay started again after keeping it, else
  /// what the relay got wrong (a [LedgerWrongKind]'s name).
  String _kindOf(String account, int at, String said, {required bool same, required String? relay}) {
    // Another route took it, or their relay is another: nothing this relay said.
    if (relay == null || !same || (said != 'p' && said != 'k')) return 'made';
    // It came, and could not be opened here: sealed for another device of this account, which it was passed on to.
    if (ledger.unopenedNear(account, at, unopenedNear)) return 'made';
    final here = ledger.connectedAt(relay, at, slack: slack);
    if (said == 'p') return here ? LedgerWrongKind.passed.name : 'made';
    // Kept: for someone the relay held to be away, while this device was connected to it.
    if (here) return LedgerWrongKind.away.name;
    // Kept, and the relay started again after: gone with the restart, what it keeps living in memory (the review, D2).
    if (ledger.restartedAfter(relay, at, slack: slack)) return 'restart';
    // Kept and never handed over to this device: the relay hands what it kept to whichever of the account's devices signs
    // in first, and nothing here can prove none did, so it is not put down against the relay (D3).
    return 'made';
  }

  /// Whether [a] and [b] are one relay's address, letter case and slashes at the end aside.
  static bool _sameRelay(String a, String b) {
    String tidy(String u) {
      var t = u.trim().toLowerCase();
      while (t.endsWith('/')) {
        t = t.substring(0, t.length - 1);
      }
      return t;
    }

    return tidy(a) == tidy(b);
  }

  /// Answers a `dif`: what [account]'s device says never came, that this device did send it and still holds, is sent
  /// again on the stream that asked.
  void _dif(Received r, String account, Map<String, dynamic> body) {
    final want = body['want'];
    if (want is! List || want.length > mostWant || !want.every(_id) || !_mayHave(_difs, account, difsAnHour)) {
      refused++;
      return;
    }
    final mine = {for (final x in ledger.sentTo(account)) x.id};
    final again = <Envelope>[];
    for (final id in want.cast<String>().toSet()) {
      if (!mine.contains(id)) continue;
      Envelope? e = board.held(account, id);
      for (final hold in holders) {
        if (e != null) break;
        try {
          e = hold(account, id);
        } catch (_) {}
      }
      if (e == null || e.id != id) continue;
      if (!_mayHave(_sentAgain, account, sentAgainAnHour)) break;
      again.add(e);
    }
    if (again.isEmpty) return;
    final peer = r.peer, arrived = r.arrived;
    // One after another, on the stream that asked: never through the relay, never by a dial.
    _quietly(() async {
      for (final e in again) {
        try {
          await board.send(peer, e, answering: arrived);
        } catch (_) {}
      }
    }());
  }

  // --- checking ------------------------------------------------------------------------------------------------------

  /// The friends the relay says are here whose devices are known.
  List<String> _here() {
    final hub = _hub;
    if (hub == null || hub.state.value != CarrierState.up) return const [];
    final here = hub.here.value;
    return [
      for (final account in here)
        if (account != p2p.me && p2p.mayLink(account) && p2p.devicesOf(account).isNotEmpty) account,
    ];
  }

  /// "Check now": dials the friends the relay says are here (at most [checkNowMost]), once a minute at most. How many
  /// were dialled.
  Future<int> checkNow() async {
    if (!canCheckNow) return 0;
    _checkedNow = nowMs;
    notifyListeners();
    return _dial(_here().take(checkNowMost).toList());
  }

  /// Brings the node up and dials each of [accounts]' devices, asking each to meet; a link already open is compared on.
  Future<int> _dial(List<String> accounts) async {
    if (accounts.isEmpty || !p2p.on) return 0;
    p2p.reason();
    try {
      await p2p.up();
    } catch (_) {
      return 0;
    }
    final until = nowMs + p2p.policy.dialFor.inMilliseconds;
    var dialled = 0;
    for (final account in accounts) {
      final devices = p2p.devicesOf(account);
      final linked = [for (final d in devices) if (p2p.carrier.linkedTo(account, d.nodeId)) d];
      if (linked.isNotEmpty) {
        for (final d in linked) {
          _compare(account, d.nodeId);
        }
        continue;
      }
      _quietly(p2p.meet(account, until));
      for (final d in devices) {
        p2p.carrier.reach(d.nodeId, account);
      }
      dialled++;
    }
    return dialled;
  }

  /// Sets the next round that runs by itself ([_roundNow]), and the one after it: [roundsComputer] apart on a
  /// computer, [roundsPhone] on a phone.
  void _roundSoon() {
    _round?.cancel();
    if (!_started) return;
    _round = _timer(p2p.policy.stayUp ? roundsComputer : roundsPhone, () {
      _round = null;
      _quietly(_roundNow());
      _roundSoon();
    });
  }

  /// A round by itself: while the app is on screen and no direct link is in use, up to [roundMost] friends the relay
  /// says are here and not compared in a day.
  Future<void> _roundNow() async {
    if (!_started || !p2p.on || !p2p.inUse || p2p.carrier.linkedToSomeone) return;
    final now = nowMs;
    final due = [for (final a in _here()) if (now - ledger.comparedWith(a) >= roundAfter.inMilliseconds) a];
    await _dial(due.take(roundMost).toList());
  }

  @override
  void dispose() {
    unawaited(stop());
    super.dispose();
  }
}
